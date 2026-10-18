package com.sankalpa.application.conversation;

import com.sankalpa.application.SankalpaUseCases;
import com.sankalpa.application.port.SankalpaClock;
import com.sankalpa.domain.*;
import com.sankalpa.domain.commitment.Commitment;
import com.sankalpa.domain.commitment.PeriodUnit;

import java.time.Duration;
import java.time.LocalDate;
import java.time.LocalDateTime;
import java.util.List;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;

public final class ProposalService implements ConversationUseCases {
    private static final int MAX_SUMMARY = 200;
    private static final int MAX_DESCRIPTION = 2_000;
    private static final Set<String> DECLARATION_FIELDS = Set.of(
            "title", "description", "actionType", "startDate", "periodUnit",
            "timesPerPeriod", "periodCount");
    private final ProposalRepository proposals;
    private final SankalpaUseCases sankalpas;
    private final SankalpaClock clock;
    private final Duration lifetime;
    private final java.util.function.Supplier<UUID> serviceInstance;
    private final String timezone;

    public ProposalService(ProposalRepository proposals, SankalpaUseCases sankalpas,
                           SankalpaClock clock, Duration lifetime) {
        this(proposals, sankalpas, clock, lifetime, () -> new UUID(0, 0), "UTC");
    }

    public ProposalService(ProposalRepository proposals, SankalpaUseCases sankalpas,
            SankalpaClock clock, Duration lifetime, java.util.function.Supplier<UUID> serviceInstance,
            String timezone) {
        this.serviceInstance = serviceInstance; this.timezone = timezone;
        this.proposals = proposals;
        this.sankalpas = sankalpas;
        this.clock = clock;
        this.lifetime = lifetime;
    }

    @Override
    public Proposal findBySourceRunId(UUID runId) {
        return proposals.findBySourceRunId(runId).orElse(null);
    }

    @Override
    public Proposal findPendingByThread(UUID threadId) {
        return livePending(threadId).orElse(null);
    }

    /** The thread's open proposal, recording expiry first so a stale one never blocks the thread. */
    private Optional<Proposal> livePending(UUID threadId) {
        Optional<Proposal> pending = proposals.findPendingByThread(threadId);
        if (pending.isPresent() && isExpired(pending.get())) {
            proposals.update(expire(pending.get()));
            return Optional.empty();
        }
        return pending;
    }

    private boolean isExpired(Proposal proposal) {
        return !clock.now().isBefore(proposal.expiresAt());
    }

    private Proposal expire(Proposal proposal) {
        return proposal.resolve(Proposal.Status.EXPIRED, null, null, "PROPOSAL_EXPIRED", clock.now());
    }

    @Override
    public Proposal proposeSession(UUID threadId, UUID runId, SankalpaId sankalpaId,
                                   LocalDateTime occurredAt, String summary,
                                   List<SankalpaId> alternatives) {
        return proposeSession(threadId,runId,sankalpaId,occurredAt,summary,alternatives,com.sankalpa.application.PracticeContract.SINGLE_VOW_V1);
    }
    @Override public Proposal proposeSession(UUID threadId, UUID runId, SankalpaId sankalpaId,
            LocalDateTime occurredAt, String summary, List<SankalpaId> alternatives, com.sankalpa.application.PracticeContract contract) {
        Proposal replay = proposals.findBySourceRunId(runId).orElse(null);
        if (replay != null) return replay;
        rejectPending(threadId);
        if (alternatives == null || !alternatives.isEmpty()) {
            throw new ConversationFailure("ASSISTANT_COULD_NOT_INTERPRET",
                    "The Sankalpa match is ambiguous");
        }
        if (summary == null || summary.isBlank() || summary.length() > MAX_SUMMARY) {
            throw new ConversationFailure("ASSISTANT_COULD_NOT_INTERPRET", "Invalid session summary");
        }
        Sankalpa target = sankalpas.detail(sankalpaId,contract);
        SessionId sessionId = SessionId.newId();
        target.validateSessionAt(sessionId, occurredAt, clock.now());
        LocalDateTime now = clock.now();
        Proposal proposal = new Proposal(UUID.randomUUID(), threadId, runId,
                Proposal.Kind.LOG_SESSION, Proposal.SCHEMA_VERSION,
                new Proposal.LogSessionPayload(sessionId, sankalpaId,
                        target.title().value(), occurredAt, summary.trim()),
                Proposal.Status.PENDING, null, null, null, now, now.plus(lifetime), null);
        proposals.insert(proposal);
        return proposal;
    }

    @Override
    public Proposal proposeDeclaration(UUID threadId, UUID runId, String title, String description,
                                       ActionType actionType, LocalDate startDate,
                                       PeriodUnit periodUnit, int timesPerPeriod,
                                       Integer periodCount, List<String> inferredFields) {
        Proposal replay = proposals.findBySourceRunId(runId).orElse(null);
        if (replay != null) return replay;
        rejectPending(threadId);
        if (description != null && description.length() > MAX_DESCRIPTION) {
            throw new ConversationFailure("ASSISTANT_COULD_NOT_INTERPRET",
                    "Description exceeds 2000 characters");
        }
        if (inferredFields == null || inferredFields.stream().anyMatch(f -> !DECLARATION_FIELDS.contains(f))) {
            throw new ConversationFailure("ASSISTANT_COULD_NOT_INTERPRET", "Invalid inferred field");
        }
        Title validatedTitle = new Title(title);
        Description validatedDescription = new Description(description);
        Commitment commitment = new Commitment(startDate, periodUnit, timesPerPeriod, periodCount);
        Sankalpa.declare(SankalpaId.newId(), validatedTitle, validatedDescription, actionType,
                commitment, clock.now(), clock.today());
        LocalDateTime now = clock.now();
        Proposal proposal = new Proposal(UUID.randomUUID(), threadId, runId,
                Proposal.Kind.DECLARE_SANKALPA, Proposal.SCHEMA_VERSION,
                new Proposal.DeclareSankalpaPayload(validatedTitle.value(), validatedDescription.value(),
                        actionType, startDate, periodUnit, timesPerPeriod, periodCount, inferredFields),
                Proposal.Status.PENDING, null, null, null, now, now.plus(lifetime), null);
        proposals.insert(proposal);
        return proposal;
    }

    @Override
    public Resolution confirm(UUID threadId, UUID proposalId, UUID confirmationId) {
        return confirm(threadId,proposalId,confirmationId,com.sankalpa.application.PracticeContract.SINGLE_VOW_V1);
    }
    @Override public Resolution confirm(UUID threadId, UUID proposalId, UUID confirmationId, com.sankalpa.application.PracticeContract contract) {
        return confirm(threadId, proposalId, confirmationId, contract, false);
    }
    @Override public Resolution confirm(UUID threadId, UUID proposalId, UUID confirmationId,
            com.sankalpa.application.PracticeContract contract, boolean batchSupported) {
        Proposal proposal = lockedOwned(threadId, proposalId);
        if (proposal.kind() == Proposal.Kind.LOG_SESSIONS) {
            if (!batchSupported) throw new ConversationFailure("ASSISTANT_BATCH_UNSUPPORTED", "Update the app to confirm multiple sessions.");
            return confirmBatch(proposal, confirmationId, contract);
        }
        if (proposal.status() == Proposal.Status.EXECUTED
                && confirmationId.equals(proposal.confirmationId())) return new Resolution(proposal, true);
        if (proposal.status() == Proposal.Status.EXPIRED) return new Resolution(proposal, true);
        if (proposal.status() != Proposal.Status.PENDING) alreadyResolved();
        if (isExpired(proposal)) {
            // Returned rather than thrown, so the EXPIRED status commits with this transaction.
            Proposal expired = expire(proposal);
            proposals.update(expired);
            return new Resolution(expired, false);
        }
        try {
            UUID result;
            if (proposal.payload() instanceof Proposal.LogSessionPayload payload) {
                result = sankalpas.logSession(payload.sankalpaId(), payload.sessionId(),
                        payload.occurredAt(),contract).session().id().value();
            } else if (proposal.payload() instanceof Proposal.DeclareSankalpaPayload payload) {
                result = sankalpas.declare(payload.title(), payload.description(), payload.actionType(),
                        payload.startDate(), payload.periodUnit(), payload.timesPerPeriod(),
                        payload.periodCount()).id().value();
            } else throw new IllegalStateException("Unsupported proposal payload");
            Proposal executed = proposal.resolve(Proposal.Status.EXECUTED, confirmationId, result,
                    null, clock.now());
            proposals.update(executed);
            return new Resolution(executed, false);
        } catch (DomainException failure) {
            Proposal rejected = proposal.resolve(Proposal.Status.REJECTED, confirmationId, null,
                    failure.code(), clock.now());
            proposals.update(rejected);
            return new Resolution(rejected, false);
        }
    }

    @Override public Proposal proposeSessions(UUID thread, UUID run, SankalpaId id, BatchSessionPlan plan,
            com.sankalpa.application.PracticeContract contract) {
        Proposal replay = findBySourceRunId(run);
        if (replay != null) return replay;
        rejectPending(thread);
        var times = plan.expand();
        var target = sankalpas.detail(id, contract);
        var now = clock.now();
        // Complete contributing reads under the same outer snapshot as the revision and proposal.
        long revision = sankalpas.readSnapshot(null, () -> null).revision();
        var existing = readContributions(id, times.getFirst().toLocalDate(), times.getLast().toLocalDate(), contract);
        var entries = new java.util.ArrayList<Proposal.BatchEntry>();
        var skipped = new java.util.ArrayList<Proposal.SkippedDay>();
        var repeats = new java.util.ArrayList<LocalDateTime>();
        for (var at : times) {
            var sameDay = existing.stream().filter(s -> s.occurredAt().toLocalDate().equals(at.toLocalDate())).toList();
            var sessionId = SessionId.newId();
            try { target.validateSessionAt(sessionId, at, now); }
            catch (DomainException refusal) {
                throw new ConversationFailure("BATCH_INVALID_ENTRY", "Cannot record " + at + " (" + refusal.code() + "). Correct the request; nothing was changed.");
            }
            if (plan.mode() == BatchSessionPlan.Mode.DAILY_RANGE && !sameDay.isEmpty()) {
                skipped.add(new Proposal.SkippedDay(at.toLocalDate(), sameDay.stream().map(Session::id).toList()));
                continue;
            }
            entries.add(new Proposal.BatchEntry(sessionId, at));
            if (existing.stream().anyMatch(s -> s.occurredAt().equals(at))) repeats.add(at);
        }
        if (entries.isEmpty()) return null;
        var payload = new Proposal.LogSessionsPayload(id, target.title().value(), target.seriesId(), contract,
                serviceInstance.get(), timezone, plan, revision, times.size(), entries, skipped, repeats);
        var proposal = new Proposal(UUID.randomUUID(), thread, run, Proposal.Kind.LOG_SESSIONS, 2,
                payload, Proposal.Status.PENDING, null, null, null, now, now.plus(lifetime), null);
        proposals.insert(proposal);
        return proposal;
    }

    private List<Session> readContributions(SankalpaId id, LocalDate from, LocalDate through,
            com.sankalpa.application.PracticeContract contract) {
        var existing = new java.util.ArrayList<Session>();
        if (contract == com.sankalpa.application.PracticeContract.SINGLE_VOW_V1) {
            long total = -1;
            for (int pageNumber = 0; ; pageNumber++) {
                var page = sankalpas.sessions(id, from, through, pageNumber, 200);
                if (total < 0) total = page.totalElements();
                if (total > 10_000 || total != page.totalElements()) incompleteHistory();
                existing.addAll(page.content());
                if (pageNumber + 1 >= page.totalPages()) break;
                if (page.content().isEmpty() || existing.size() > 10_000) incompleteHistory();
            }
            if (existing.size() != total) incompleteHistory();
        } else {
            com.sankalpa.application.SessionBoundary after = null;
            do {
                var page = sankalpas.cursorSessions(id, from, through, after, 200, contract);
                existing.addAll(page.content());
                if (existing.size() > 10_000 || (page.hasMore() && page.content().isEmpty())) incompleteHistory();
                if (!page.hasMore()) break;
                var last = page.content().getLast();
                var next = new com.sankalpa.application.SessionBoundary(last.occurredAt(), last.id());
                if (next.equals(after)) incompleteHistory();
                after = next;
            } while (true);
        }
        if (existing.stream().map(Session::id).distinct().count() != existing.size()) incompleteHistory();
        return existing;
    }
    private static void incompleteHistory() {
        throw new ConversationFailure("BATCH_READ_INCOMPLETE", "History could not be read completely. Choose a smaller range.");
    }

    private Resolution confirmBatch(Proposal proposal, UUID confirmation,
            com.sankalpa.application.PracticeContract contract) {
        var p = (Proposal.LogSessionsPayload) proposal.payload();
        if (!p.serviceInstanceId().equals(serviceInstance.get()) || p.contract() != contract)
            throw new ConversationFailure("ASSISTANT_BATCH_UNSUPPORTED", "Use the original service and practice contract to resolve this proposal.");
        if ((proposal.status() == Proposal.Status.EXECUTED || proposal.status() == Proposal.Status.REJECTED)
                && confirmation.equals(proposal.confirmationId())) return new Resolution(proposal, true);
        if (proposal.status() == Proposal.Status.EXPIRED) return new Resolution(proposal, true);
        if (proposal.status() != Proposal.Status.PENDING) alreadyResolved();
        if (isExpired(proposal)) {
            var expired = expire(proposal); proposals.update(expired); return new Resolution(expired, false);
        }
        var target = sankalpas.lockForSessionBatch(p.sankalpaId(), contract);
        if (sankalpas.readSnapshot(null, () -> null).revision() != p.baseRevision())
            throw new BatchRejection("PROPOSAL_STALE");
        // Refusals MUST escape the transaction, even if an earlier entry already wrote data.
        try {
            var now = clock.now();
            for (var entry : p.entries()) target.validateSessionAt(entry.sessionId(), entry.occurredAt(), now);
            clock.at(now, () -> {
                for (var entry : p.entries())
                    sankalpas.logSession(p.sankalpaId(), entry.sessionId(), entry.occurredAt(), contract);
                return null;
            });
        } catch (DomainException failure) { throw new BatchRejection(failure.code()); }
        var executed = proposal.resolve(Proposal.Status.EXECUTED, confirmation, null, null, clock.now());
        proposals.update(executed);
        return new Resolution(executed, false);
    }

    @Override public Resolution rejectBatch(UUID thread, UUID id, UUID confirmation, String code) {
        var proposal = lockedOwned(thread, id);
        if (proposal.kind() != Proposal.Kind.LOG_SESSIONS) alreadyResolved();
        if (proposal.status() != Proposal.Status.PENDING) {
            if (confirmation.equals(proposal.confirmationId())) return new Resolution(proposal, true);
            alreadyResolved();
        }
        var rejected = proposal.resolve(Proposal.Status.REJECTED, confirmation, null, code, clock.now());
        proposals.update(rejected);
        return new Resolution(rejected, false);
    }

    @Override
    public Resolution cancel(UUID threadId, UUID proposalId) {
        Proposal proposal = lockedOwned(threadId, proposalId);
        // Cancelling asks that nothing be changed, which already holds for these outcomes.
        if (proposal.status() == Proposal.Status.CANCELLED
                || proposal.status() == Proposal.Status.EXPIRED
                || proposal.status() == Proposal.Status.REJECTED) return new Resolution(proposal, true);
        if (proposal.status() != Proposal.Status.PENDING) alreadyResolved();
        Proposal cancelled = proposal.resolve(Proposal.Status.CANCELLED, null, null, null, clock.now());
        proposals.update(cancelled);
        return new Resolution(cancelled, false);
    }

    private Proposal lockedOwned(UUID threadId, UUID proposalId) {
        Proposal proposal = proposals.findByIdForUpdate(proposalId)
                .orElseThrow(() -> new ConversationFailure("PROPOSAL_NOT_FOUND", "Proposal not found"));
        if (!proposal.threadId().equals(threadId) || proposal.schemaVersion() != (proposal.kind() == Proposal.Kind.LOG_SESSIONS ? 2 : Proposal.SCHEMA_VERSION)) {
            throw new ConversationFailure("PROPOSAL_NOT_FOUND", "Proposal not found");
        }
        return proposal;
    }

    private void rejectPending(UUID threadId) {
        if (livePending(threadId).isPresent()) {
            throw new ConversationFailure("PROPOSAL_ALREADY_RESOLVED",
                    "Confirm or cancel the pending proposal first");
        }
    }

    private static void alreadyResolved() {
        throw new ConversationFailure("PROPOSAL_ALREADY_RESOLVED", "Proposal is already resolved");
    }
}
