package com.sankalpa.application;

import com.sankalpa.application.port.SankalpaClock;
import com.sankalpa.application.port.SankalpaRepository;
import com.sankalpa.application.port.SessionRepository;
import com.sankalpa.domain.*;
import com.sankalpa.domain.commitment.*;
import com.sankalpa.domain.lifecycle.CompletionOutcome;
import com.sankalpa.domain.lifecycle.LifecycleTransition;
import java.time.LocalDate;
import java.time.LocalDateTime;
import java.util.List;

public class SankalpaService implements SankalpaUseCases {
    public static final int MAX_SESSION_PAGE_SIZE = 200;
    private final SankalpaRepository sankalpas;
    private final SessionRepository sessions;
    private final SankalpaClock clock;
    private final PeriodOutcomeCalculator outcomeCalculator = new PeriodOutcomeCalculator();

    public SankalpaService(SankalpaRepository sankalpas, SessionRepository sessions, SankalpaClock clock) {
        this.sankalpas = sankalpas;
        this.sessions = sessions;
        this.clock = clock;
    }

    @Override
    public Sankalpa declare(String title, String description, ActionType actionType,
                            LocalDate startDate, PeriodUnit periodUnit,
                            int timesPerPeriod, Integer periodCount) {
        Sankalpa result = Sankalpa.declare(
                SankalpaId.newId(), new Title(title), new Description(description), actionType,
                new Commitment(startDate, periodUnit, timesPerPeriod, periodCount),
                clock.now(), clock.today());
        sankalpas.saveNew(result);
        sankalpas.incrementRevision();
        return result;
    }

    @Override
    public List<Sankalpa> list() { return list(PracticeContract.SINGLE_VOW_V1); }

    @Override
    public List<Sankalpa> list(PracticeContract contract) {
        List<Sankalpa> all = sankalpas.findAll();
        if (all.stream().anyMatch(v -> v.extensionOf().isPresent())) contract.requireLinked();
        return all;
    }

    @Override
    public Sankalpa detail(SankalpaId id) { return detail(id, PracticeContract.SINGLE_VOW_V1); }

    @Override
    public Sankalpa detail(SankalpaId id, PracticeContract contract) { return readable(id, contract); }

    @Override
    public Sankalpa begin(SankalpaId id, LocalDateTime effectiveAt) { return begin(id, effectiveAt, PracticeContract.SINGLE_VOW_V1); }

    @Override
    public Sankalpa begin(SankalpaId id, LocalDateTime effectiveAt, PracticeContract contract) {
        Sankalpa sankalpa = locked(id);
        checkContract(sankalpa, contract);
        LocalDateTime now = clock.now();
        sankalpa.begin(effectiveAt == null ? now : effectiveAt, now);
        sankalpas.save(sankalpa);
        sankalpas.incrementRevision();
        return sankalpa;
    }

    @Override
    public Sankalpa pause(SankalpaId id) { return pause(id, PracticeContract.SINGLE_VOW_V1); }

    @Override
    public Sankalpa pause(SankalpaId id, PracticeContract contract) { return transition(id, Transition.PAUSE, null, contract); }

    @Override
    public Sankalpa resume(SankalpaId id) { return resume(id, PracticeContract.SINGLE_VOW_V1); }

    @Override
    public Sankalpa resume(SankalpaId id, PracticeContract contract) { return transition(id, Transition.RESUME, null, contract); }

    @Override
    public Sankalpa complete(SankalpaId id, CompletionOutcome outcome) { return complete(id, outcome, PracticeContract.SINGLE_VOW_V1); }

    @Override
    public Sankalpa complete(SankalpaId id, CompletionOutcome outcome, PracticeContract contract) {
        return transition(id, Transition.COMPLETE, outcome, contract);
    }

    @Override
    public Sankalpa stop(SankalpaId id) { return stop(id, PracticeContract.SINGLE_VOW_V1); }

    @Override
    public Sankalpa stop(SankalpaId id, PracticeContract contract) { return transition(id, Transition.STOP, null, contract); }

    private Sankalpa transition(SankalpaId id, Transition transition, CompletionOutcome outcome, PracticeContract contract) {
        Sankalpa sankalpa = locked(id);
        checkContract(sankalpa, contract);
        LocalDateTime now = clock.now();
        switch (transition) {
            case PAUSE -> sankalpa.pause(now);
            case RESUME -> sankalpa.resume(now);
            case COMPLETE -> sankalpa.complete(outcome, now);
            case STOP -> sankalpa.stop(now);
        }
        sankalpas.save(sankalpa);
        sankalpas.incrementRevision();
        return sankalpa;
    }

    @Override
    public SessionLogResult logSession(SankalpaId id, SessionId sessionId, LocalDateTime occurredAt) { return logSession(id, sessionId, occurredAt, PracticeContract.SINGLE_VOW_V1); }

    @Override
    public SessionLogResult logSession(SankalpaId id, SessionId sessionId, LocalDateTime occurredAt, PracticeContract contract) {
        Sankalpa sankalpa = locked(id);

        var identity = sessions.findIdentity(sessionId);
        if (identity.isPresent()) {
            SessionIdentity stored = identity.get();
            if (!stored.sankalpaId().equals(id)) {
                throw identityConflict(sessionId);
            }
            if (stored.state() == SessionIdentityState.DELETED) {
                throw new SessionDeletedException("Session " + sessionId + " was permanently deleted");
            }
            Session existing = sessions.findById(sessionId)
                    .orElseThrow(() -> new IllegalStateException(
                            "ACTIVE session identity has no session fact: " + sessionId));
            if (!existing.occurredAt().equals(occurredAt)) {
                throw identityConflict(sessionId);
            }
            return new SessionLogResult(existing, false);
        }

        checkContract(sankalpa, contract);
        Session session = sankalpa.logSession(sessionId, occurredAt, clock.now());
        sessions.claimIdentity(new SessionIdentity(sessionId, id, SessionIdentityState.ACTIVE));
        sessions.save(session);
        sankalpas.incrementRevision();
        return new SessionLogResult(session, true);
    }

    @Override
    public void deleteSession(SankalpaId id, SessionId sessionId) { deleteSession(id, sessionId, PracticeContract.SINGLE_VOW_V1); }

    @Override
    public void deleteSession(SankalpaId id, SessionId sessionId, PracticeContract contract) {
        Sankalpa owner = locked(id);

        var identity = sessions.findIdentity(sessionId);
        if (identity.isEmpty()) {
            checkContract(owner, contract);
            sessions.claimIdentity(new SessionIdentity(sessionId, id, SessionIdentityState.DELETED));
            sankalpas.incrementRevision();
            return;
        }
        SessionIdentity stored = identity.get();
        if (!stored.sankalpaId().equals(id)) {
            throw identityConflict(sessionId);
        }
        if (stored.state() == SessionIdentityState.DELETED) return;

        checkContract(owner, contract);
        sessions.delete(sessionId);
        sessions.markDeleted(sessionId);
        sankalpas.incrementRevision();
    }

    private SessionIdentityConflictException identityConflict(SessionId id) {
        return new SessionIdentityConflictException(
                "Session identity " + id + " is already bound to different values");
    }

    @Override
    public PageResult<Session> sessions(SankalpaId id, LocalDate from, LocalDate until,
                                        int page, int size) {
        readable(id, PracticeContract.SINGLE_VOW_V1);
        if ((from == null) != (until == null) || (from != null && from.isAfter(until))) {
            throw new DomainException("INVALID_DATE_RANGE", "from and until must be supplied together, with from on or before until");
        }
        if (page < 0 || size < 1 || size > MAX_SESSION_PAGE_SIZE) {
            throw new DomainException("INVALID_PAGINATION",
                    "page must be non-negative and size must be between 1 and " + MAX_SESSION_PAGE_SIZE);
        }
        long offset = Math.multiplyExact((long) page, size);
        long totalElements = sessions.countForSankalpa(id, from, until);
        long totalPages = totalElements == 0 ? 0 : ((totalElements - 1) / size) + 1;
        return new PageResult<>(sessions.findPageForSankalpa(id, from, until, offset, size),
                page, size, totalElements, totalPages);
    }

    @Override
    public List<LifecycleTransition> lifecycleHistory(SankalpaId id) { return lifecycleHistory(id, PracticeContract.SINGLE_VOW_V1); }

    @Override
    public List<LifecycleTransition> lifecycleHistory(SankalpaId id, PracticeContract contract) {
        return readable(id, contract).lifecycle().transitions();
    }

    @Override
    public List<PeriodOutcome> periodOutcomes(SankalpaId id, LocalDate from, LocalDate until) { return periodOutcomes(id, from, until, PracticeContract.SINGLE_VOW_V1); }

    @Override
    public List<PeriodOutcome> periodOutcomes(SankalpaId id, LocalDate from, LocalDate until, PracticeContract contract) {
        Sankalpa sankalpa = readable(id, contract);
        List<PeriodWindow> windows = sankalpa.commitment().windowsStartingBetween(from, until);
        if (windows.isEmpty()) return List.of();
        LocalDate sessionFrom = windows.getFirst().start();
        LocalDate sessionUntil = windows.getLast().end();
        List<Session> relevantSessions = contributingSessions(sankalpa, sessionFrom, sessionUntil);
        return outcomeCalculator.calculate(sankalpa.commitment(), sankalpa.lifecycle(),
                relevantSessions, from, until, clock.today());
    }

    @Override
    public ExtensionResult extend(SankalpaId sourceId, SankalpaId extensionId, int count, PracticeContract contract) {
        contract.requireLinked();
        Sankalpa source = locked(sourceId);
        var existing = sankalpas.findById(extensionId);
        if (existing.isPresent()) {
            Sankalpa child = existing.get();
            if (child.extensionOf().filter(sourceId::equals).isPresent()
                    && java.util.Objects.equals(child.commitment().periodCount(), count)) {
                return new ExtensionResult(child, false);
            }
            throw new PracticeException("EXTENSION_IDENTITY_CONFLICT", "Extension identity has different input");
        }
        var child = sankalpas.findDirectExtension(sourceId);
        if (child.isPresent()) throw new PracticeException("EXTENSION_ALREADY_EXISTS", "This vow already has an extension",
                java.util.Map.of("extensionId", child.get().id().toString()));
        Sankalpa extension = source.extend(extensionId, count, clock.now());
        sankalpas.saveNew(extension);
        sankalpas.incrementRevision();
        return new ExtensionResult(extension, true);
    }

    @Override
    public List<Sankalpa> linkedSeries(SankalpaId id, PracticeContract contract) {
        contract.requireLinked();
        return sankalpas.findSeriesMembers(require(id).seriesId()).stream()
                .sorted(java.util.Comparator.comparingInt(v -> v.commitment().periodCount() == null ? 0 : v.commitment().periodCount()))
                .toList();
    }

    @Override
    public long totalSessionCount(SankalpaId id) { return totalSessionCounts(List.of(require(id))).get(id); }

    @Override
    public List<SankalpaId> contributors(Session session) {
        var members = sankalpas.findSeriesMembers(require(session.sankalpaId()).seriesId());
        var owners = SessionContributions.owners(members);
        return members.stream().filter(v -> SessionContributions.contributes(session, v, owners))
                .sorted(java.util.Comparator.comparingInt(v -> v.commitment().periodCount() == null ? 0 : v.commitment().periodCount()))
                .map(Sankalpa::id).toList();
    }

    @Override
    public java.util.Map<SankalpaId, Long> totalSessionCounts(List<Sankalpa> vows) {
        var counts = new java.util.HashMap<SankalpaId, Long>();
        var groups = vows.stream().collect(java.util.stream.Collectors.groupingBy(Sankalpa::seriesId));
        for (var group : groups.entrySet()) {
            var members = sankalpas.findSeriesMembers(group.getKey());
            var owners = SessionContributions.owners(members);
            var ids = members.stream().map(Sankalpa::id).toList();
            group.getValue().forEach(v -> counts.put(v.id(), 0L));
            SessionBoundary after = null;
            while (true) {
                var chunk = sessions.scanCandidates(ids, null, null, after, 200);
                for (var fact : chunk) {
                    for (var vow : group.getValue()) {
                        if (SessionContributions.contributes(fact, vow, owners)) counts.merge(vow.id(), 1L, Long::sum);
                    }
                }
                if (chunk.size() < 200) break;
                var last = chunk.getLast();
                after = new SessionBoundary(last.occurredAt(), last.id());
            }
        }
        return java.util.Map.copyOf(counts);
    }

    @Override
    public java.util.Map<SessionId, List<SankalpaId>> contributors(List<Session> facts) {
        var result = new java.util.HashMap<SessionId, List<SankalpaId>>();
        // Load the collection once for a page, including pages that span several series.
        var vows = sankalpas.findAll();
        var owners = SessionContributions.owners(vows);
        var groups = vows.stream().collect(java.util.stream.Collectors.groupingBy(Sankalpa::seriesId));
        for (var fact : facts) {
            var owner = owners.get(fact.sankalpaId());
            if (owner == null) throw new IllegalStateException("Missing session owner");
            result.put(fact.id(), groups.get(owner.seriesId()).stream()
                    .filter(v -> SessionContributions.contributes(fact, v, owners))
                    .sorted(java.util.Comparator.comparingInt(v -> v.commitment().periodCount() == null ? 0 : v.commitment().periodCount()))
                    .map(Sankalpa::id).toList());
        }
        return java.util.Map.copyOf(result);
    }

    private List<Session> contributingSessions(Sankalpa target, LocalDate from, LocalDate until) {
        var members = sankalpas.findSeriesMembers(target.seriesId());
        var owners = SessionContributions.owners(members);
        var ids = members.stream().map(Sankalpa::id).toList();
        var result = new java.util.ArrayList<Session>();
        SessionBoundary after = null;
        while (true) {
            var chunk = sessions.scanCandidates(ids, from, until, after, 200);
            for (Session fact : chunk) if (SessionContributions.contributes(fact, target, owners)) result.add(fact);
            if (chunk.size() < 200) break;
            var last = chunk.getLast(); after = new SessionBoundary(last.occurredAt(), last.id());
        }
        return List.copyOf(result);
    }

    @Override
    public CursorPage cursorSessions(SankalpaId targetId, LocalDate from, LocalDate until,
            SessionBoundary after, int size, PracticeContract contract) {
        contract.requireLinked();
        if ((from == null) != (until == null) || (from != null && from.isAfter(until)))
            throw new DomainException("INVALID_DATE_RANGE", "Supply an ordered range or no range");
        if (size < 1 || size > MAX_SESSION_PAGE_SIZE) throw new DomainException("INVALID_PAGINATION", "Size must be 1–200");
        Sankalpa target = targetId == null ? null : require(targetId);
        var members = target == null ? sankalpas.findAll() : sankalpas.findSeriesMembers(target.seriesId());
        var owners = SessionContributions.owners(members);
        var ids = members.stream().map(Sankalpa::id).toList();
        var eligible = new java.util.ArrayList<Session>();
        while (eligible.size() <= size) {
            var chunk = sessions.scanCandidates(ids, from, until, after, 200);
            for (Session fact : chunk) {
                if (target == null || SessionContributions.contributes(fact, target, owners)) eligible.add(fact);
                if (eligible.size() > size) break;
            }
            if (eligible.size() > size || chunk.size() < 200) break;
            var last = chunk.getLast(); after = new SessionBoundary(last.occurredAt(), last.id());
        }
        return new CursorPage(eligible.subList(0, Math.min(size, eligible.size())), eligible.size() > size);
    }

    @Override public Sankalpa lockForSessionBatch(SankalpaId id, PracticeContract contract) {
        var target = locked(id); checkContract(target, contract); return target;
    }
    @Override public <T> PracticeSnapshot<T> writeSnapshot(java.util.function.Supplier<T> query) {
        T result = query.get();
        return new PracticeSnapshot<>(sankalpas.readRevision(), result);
    }

    @Override
    public <T> PracticeSnapshot<T> readSnapshot(Long expectedRevision, java.util.function.Supplier<T> query) {
        long revision = sankalpas.readRevision();
        if (expectedRevision != null && expectedRevision != revision)
            throw new PracticeException("READ_SNAPSHOT_CHANGED", "Practice changed; restart this read");
        T result = query.get();
        return new PracticeSnapshot<>(sankalpas.readRevision(), result);
    }

    private Sankalpa locked(SankalpaId id) {
        Sankalpa located = require(id);
        sankalpas.acquireSeriesWriteGuard(located.seriesId());
        return sankalpas.findByIdForUpdate(id).orElseThrow();
    }
    private Sankalpa readable(SankalpaId id, PracticeContract contract) {
        Sankalpa vow = require(id); checkContract(vow, contract); return vow;
    }
    private void checkContract(Sankalpa vow, PracticeContract contract) {
        if (sankalpas.findSeriesMembers(vow.seriesId()).size() > 1) contract.requireLinked();
    }

    private Sankalpa require(SankalpaId id) {
        return sankalpas.findById(id)
                .orElseThrow(() -> new NotFoundException("Sankalpa " + id + " was not found"));
    }

    private enum Transition { PAUSE, RESUME, COMPLETE, STOP }
}
