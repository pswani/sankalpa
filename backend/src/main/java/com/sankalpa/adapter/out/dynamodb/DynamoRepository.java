package com.sankalpa.adapter.out.dynamodb;

import com.fasterxml.jackson.databind.*;
import com.fasterxml.jackson.databind.node.ObjectNode;
import com.sankalpa.application.*;
import com.sankalpa.application.port.*;
import com.sankalpa.application.conversation.*;
import com.sankalpa.domain.*;
import com.sankalpa.domain.commitment.*;
import com.sankalpa.domain.lifecycle.*;
import java.time.*;
import java.time.format.DateTimeFormatter;
import java.util.*;

/** Three repository ports share one transaction and canonical document encoding. */
public final class DynamoRepository implements SankalpaRepository, SessionRepository, ProposalRepository {
    private final DynamoUnitOfWork tx;
    private final ObjectMapper json;
    private static final DateTimeFormatter TIME = DateTimeFormatter.ofPattern("uuuu-MM-dd'T'HH:mm:ss.SSSSSSSSS");
    public DynamoRepository(DynamoUnitOfWork tx, ObjectMapper json) { this.tx = tx; this.json = json; }
    public record Vow(String id, String title, String description, ActionType actionType,
            LocalDate startDate, PeriodUnit periodUnit, int timesPerPeriod, Integer periodCount,
            LocalDateTime declaredAt, LifecycleState currentState, int version, String seriesId,
            String extensionOf, List<LifecycleTransition> history) {}
    public record StoredSession(String id, String owner, SessionIdentityState state,
            LocalDateTime occurredAt, LocalDateTime loggedAt) {}
    public record StoredProposal(UUID id, UUID threadId, UUID sourceRunId, Proposal.Kind kind, int schemaVersion,
            JsonNode payload, Proposal.Status status, UUID confirmationId, UUID resultResourceId, String failureCode,
            LocalDateTime createdAt, LocalDateTime expiresAt, LocalDateTime resolvedAt) {}
    private <T> T decode(ObjectNode value, Class<T> type) {
        try { return json.treeToValue(value, type); }
        catch (Exception failure) { throw new IllegalStateException("Invalid stored " + type.getSimpleName()); }
    }
    private ObjectNode encode(Object value) { return json.valueToTree(value); }
    private Sankalpa vow(ObjectNode node) {
        Vow v = decode(node, Vow.class);
        return Sankalpa.reconstitute(SankalpaId.parse(v.id()), new Title(v.title()), new Description(v.description()), v.actionType(),
                new Commitment(v.startDate(), v.periodUnit(), v.timesPerPeriod(), v.periodCount()), v.declaredAt(),
                new LifecycleTimeline(v.currentState(), v.history()), v.version(), SankalpaId.parse(v.seriesId()),
                v.extensionOf() == null ? null : SankalpaId.parse(v.extensionOf()));
    }
    public Optional<Sankalpa> findById(SankalpaId id) { return Optional.ofNullable(tx.get("VOW#" + id)).map(this::vow); }
    public Optional<Sankalpa> findByIdForUpdate(SankalpaId id) { return findById(id); }
    public void acquireSeriesWriteGuard(SankalpaId root) { findById(root).orElseThrow(); }
    public List<Sankalpa> findAll() {
        return tx.query("VOW#").values().stream().map(this::vow).sorted(Comparator.comparing(Sankalpa::declaredAt).reversed()).toList();
    }
    public List<Sankalpa> findSeriesMembers(SankalpaId root) {
        return tx.query("SERIES#" + root + "#").values().stream().map(v -> findById(SankalpaId.parse(v.path("id").asText())).orElseThrow()).toList();
    }
    public Optional<Sankalpa> findDirectExtension(SankalpaId source) {
        var claim = tx.get("EXTENSION#" + source);
        return claim == null ? Optional.empty() : findById(SankalpaId.parse(claim.path("id").asText()));
    }
    public void saveNew(Sankalpa value) {
        if (tx.get("VOW#" + value.id()) != null) throw new com.sankalpa.application.ConcurrentModificationException("Vow identity already exists");
        if (value.extensionOf().isPresent()) {
            String key = "EXTENSION#" + value.extensionOf().get();
            if (tx.get(key) != null) throw new PracticeException("EXTENSION_ALREADY_EXISTS", "This vow already has an extension");
            tx.put(key, json.createObjectNode().put("id", value.id().toString()));
        }
        persist(value);
        tx.put("SERIES#" + value.seriesId() + "#" + String.format("%04d", value.commitment().periodCount() == null ? 0 : value.commitment().periodCount()) + "#" + value.id(),
                json.createObjectNode().put("id", value.id().toString()));
    }
    public void save(Sankalpa value) {
        var old = findById(value.id());
        if (old.isEmpty()) { saveNew(value); return; }
        var history = old.get().lifecycle().transitions();
        var updated = value.lifecycle().transitions();
        if (old.get().version() != value.version() || history.size() > updated.size() || !updated.subList(0, history.size()).equals(history))
            throw new com.sankalpa.application.ConcurrentModificationException("Vow version or audit changed");
        value.markPersistedAtVersion(Math.addExact(value.version(), 1)); persist(value);
    }
    @Override public void saveBeginCorrection(Sankalpa corrected, LifecycleTransition expected) {
        var old = findById(corrected.id()).orElseThrow();
        if (old.version() != corrected.version() || old.lifecycle().transitions().size() != 1
                || !old.lifecycle().transitions().getFirst().equals(expected) || !expected.beginCorrections().isEmpty())
            throw new com.sankalpa.application.ConcurrentModificationException("Begin changed during correction");
        corrected.markPersistedAtVersion(Math.addExact(corrected.version(), 1)); persist(corrected);
    }
    private void persist(Sankalpa v) {
        tx.put("VOW#" + v.id(), encode(new Vow(v.id().toString(), v.title().value(), v.description().value(), v.actionType(),
                v.commitment().startDate(), v.commitment().periodUnit(), v.commitment().timesPerPeriod(), v.commitment().periodCount(),
                v.declaredAt(), v.lifecycle().current(), v.version(), v.seriesId().toString(), v.extensionOf().map(Object::toString).orElse(null), v.lifecycle().transitions())));
    }
    public long readRevision() { return tx.get("META").get("practiceRevision").asLong(); }
    public void incrementRevision() {
        var meta = tx.get("META"); meta.put("practiceRevision", Math.addExact(meta.get("practiceRevision").asLong(), 1)); tx.put("META", meta);
    }
    public Optional<SessionIdentity> findIdentity(SessionId id) {
        return Optional.ofNullable(tx.get("SESSION#" + id)).map(n -> decode(n, StoredSession.class))
                .map(s -> new SessionIdentity(id, SankalpaId.parse(s.owner()), s.state()));
    }
    public void claimIdentity(SessionIdentity identity) {
        if (tx.get("SESSION#" + identity.sessionId()) != null) throw new DocumentStore.Conflict();
        tx.put("SESSION#" + identity.sessionId(), encode(new StoredSession(identity.sessionId().toString(), identity.sankalpaId().toString(), identity.state(), null, null)));
    }
    public Optional<Session> findById(SessionId id) {
        var node = tx.get("SESSION#" + id);
        if (node == null) return Optional.empty();
        var value = decode(node, StoredSession.class);
        return value.state() == SessionIdentityState.ACTIVE && value.occurredAt() != null ? Optional.of(session(value)) : Optional.empty();
    }
    private Session session(StoredSession v) { return new Session(SessionId.parse(v.id()), SankalpaId.parse(v.owner()), v.occurredAt(), v.loggedAt()); }
    private static String suffix(StoredSession s) { return TIME.format(s.occurredAt()) + "#" + s.id(); }
    public void save(Session value) {
        var stored = new StoredSession(value.id().toString(), value.sankalpaId().toString(), SessionIdentityState.ACTIVE, value.occurredAt(), value.loggedAt());
        var identity = findIdentity(value.id()).orElseThrow();
        if (identity.state() != SessionIdentityState.ACTIVE || !identity.sankalpaId().equals(value.sankalpaId())) throw new IllegalStateException("Invalid session identity");
        tx.put("SESSION#" + value.id(), encode(stored));
        tx.put("JOURNAL#" + suffix(stored), encode(stored));
        tx.put("OWNER#" + stored.owner() + "#" + suffix(stored), encode(stored));
    }
    public void delete(SessionId id) {
        var node = tx.get("SESSION#" + id);
        if (node == null) return;
        var stored = decode(node, StoredSession.class);
        if (stored.occurredAt() != null) { tx.delete("JOURNAL#" + suffix(stored)); tx.delete("OWNER#" + stored.owner() + "#" + suffix(stored)); }
    }
    public void markDeleted(SessionId id) {
        var stored = decode(tx.get("SESSION#" + id), StoredSession.class);
        tx.put("SESSION#" + id, encode(new StoredSession(stored.id(), stored.owner(), SessionIdentityState.DELETED, stored.occurredAt(), stored.loggedAt())));
    }
    private List<Session> sessions(String prefix, LocalDate from, LocalDate until) {
        return tx.query(prefix).values().stream().map(n -> session(decode(n, StoredSession.class)))
                .filter(s -> from == null || (!s.occurredAt().toLocalDate().isBefore(from) && !s.occurredAt().toLocalDate().isAfter(until)))
                .sorted(Comparator.comparing(Session::occurredAt).thenComparing(s -> s.id().toString()).reversed()).toList();
    }
    public List<Session> findForSankalpa(SankalpaId id, LocalDate from, LocalDate until) { return sessions("OWNER#" + id + "#", from, until); }
    public List<Session> findPageForSankalpa(SankalpaId id, LocalDate from, LocalDate until, long offset, int limit) {
        return findForSankalpa(id, from, until).stream().skip(offset).limit(limit).toList();
    }
    public long countForSankalpa(SankalpaId id, LocalDate from, LocalDate until) { return findForSankalpa(id, from, until).size(); }
    public List<Session> scanCandidates(List<SankalpaId> owners, LocalDate from, LocalDate until, SessionBoundary after, int limit) {
        Set<String> ids = new HashSet<>(owners.stream().map(Object::toString).toList());
        return sessions("JOURNAL#", from, until).stream().filter(s -> ids.contains(s.sankalpaId().toString()))
                .filter(s -> after == null || s.occurredAt().isBefore(after.occurredAt()) || (s.occurredAt().equals(after.occurredAt()) && s.id().toString().compareTo(after.id().toString()) < 0))
                .limit(limit).toList();
    }
    private Proposal proposal(ObjectNode n) {
        var p = decode(n, StoredProposal.class);
        try {
            Proposal.Payload payload = json.treeToValue(p.payload(), Proposal.payloadType(p.kind(), p.schemaVersion()));
            return new Proposal(p.id(), p.threadId(), p.sourceRunId(), p.kind(), p.schemaVersion(), payload, p.status(), p.confirmationId(), p.resultResourceId(), p.failureCode(), p.createdAt(), p.expiresAt(), p.resolvedAt());
        } catch (Exception failure) { throw new IllegalStateException("Invalid proposal payload"); }
    }
    private void persist(Proposal p) {
        if (json.valueToTree(p.payload()).toString().getBytes(java.nio.charset.StandardCharsets.UTF_8).length > 48 * 1024)
            throw new ConversationFailure("BATCH_READ_INCOMPLETE", "The preview is too large. Choose a smaller range.");
        tx.put("PROPOSAL#" + p.id(), encode(new StoredProposal(p.id(), p.threadId(), p.sourceRunId(), p.kind(), p.schemaVersion(), json.valueToTree(p.payload()), p.status(), p.confirmationId(), p.resultResourceId(), p.failureCode(), p.createdAt(), p.expiresAt(), p.resolvedAt())));
    }
    public void insert(Proposal p) {
        if (tx.get("RUN#" + p.sourceRunId()) != null || tx.get("PROPOSAL#" + p.id()) != null) throw new DocumentStore.Conflict();
        var thread = tx.get("THREAD#" + p.threadId());
        if (thread != null) throw new DocumentStore.Conflict();
        persist(p);
        var reference = json.createObjectNode().put("id", p.id().toString());
        tx.put("RUN#" + p.sourceRunId(), reference); tx.put("THREAD#" + p.threadId(), reference);
    }
    public Optional<Proposal> findBySourceRunId(UUID id) {
        var n = tx.get("RUN#" + id); return n == null ? Optional.empty() : findByIdForUpdate(UUID.fromString(n.path("id").asText()));
    }
    public Optional<Proposal> findPendingByThread(UUID id) {
        var n = tx.get("THREAD#" + id); return n == null ? Optional.empty() : findByIdForUpdate(UUID.fromString(n.path("id").asText())).filter(p -> p.status() == Proposal.Status.PENDING);
    }
    public Optional<Proposal> findByIdForUpdate(UUID id) { return Optional.ofNullable(tx.get("PROPOSAL#" + id)).map(this::proposal); }
    public void update(Proposal p) {
        if (tx.get("PROPOSAL#" + p.id()) == null) throw new IllegalStateException("Proposal disappeared");
        if (p.confirmationId() != null) {
            String key = "CONFIRM#" + p.confirmationId(); var old = tx.get(key);
            if (old != null && !p.id().toString().equals(old.path("id").asText())) throw new ConversationFailure("PROPOSAL_ALREADY_RESOLVED", "Confirmation identity belongs to another proposal");
            tx.put(key, json.createObjectNode().put("id", p.id().toString()));
        }
        persist(p);
        if (p.status() != Proposal.Status.PENDING) tx.delete("THREAD#" + p.threadId());
    }
}
