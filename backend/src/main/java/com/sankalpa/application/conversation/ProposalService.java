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

    public ProposalService(ProposalRepository proposals, SankalpaUseCases sankalpas,
                           SankalpaClock clock, Duration lifetime) {
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
        return proposals.findPendingByThread(threadId).orElse(null);
    }

    @Override
    public Proposal proposeSession(UUID threadId, UUID runId, SankalpaId sankalpaId,
                                   LocalDateTime occurredAt, String summary,
                                   List<SankalpaId> alternatives) {
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
        Sankalpa target = sankalpas.detail(sankalpaId);
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
        Proposal proposal = lockedOwned(threadId, proposalId);
        if (proposal.status() == Proposal.Status.EXECUTED
                && confirmationId.equals(proposal.confirmationId())) return new Resolution(proposal, true);
        if (proposal.status() != Proposal.Status.PENDING) alreadyResolved();
        if (!clock.now().isBefore(proposal.expiresAt())) {
            Proposal expired = proposal.resolve(Proposal.Status.EXPIRED, null, null,
                    "PROPOSAL_EXPIRED", clock.now());
            proposals.update(expired);
            throw new ConversationFailure("PROPOSAL_EXPIRED", "The proposal has expired");
        }
        try {
            UUID result;
            if (proposal.payload() instanceof Proposal.LogSessionPayload payload) {
                result = sankalpas.logSession(payload.sankalpaId(), payload.sessionId(),
                        payload.occurredAt()).session().id().value();
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

    @Override
    public Resolution cancel(UUID threadId, UUID proposalId) {
        Proposal proposal = lockedOwned(threadId, proposalId);
        if (proposal.status() == Proposal.Status.CANCELLED) return new Resolution(proposal, true);
        if (proposal.status() != Proposal.Status.PENDING) alreadyResolved();
        Proposal cancelled = proposal.resolve(Proposal.Status.CANCELLED, null, null, null, clock.now());
        proposals.update(cancelled);
        return new Resolution(cancelled, false);
    }

    private Proposal lockedOwned(UUID threadId, UUID proposalId) {
        Proposal proposal = proposals.findByIdForUpdate(proposalId)
                .orElseThrow(() -> new ConversationFailure("PROPOSAL_NOT_FOUND", "Proposal not found"));
        if (!proposal.threadId().equals(threadId) || proposal.schemaVersion() != Proposal.SCHEMA_VERSION) {
            throw new ConversationFailure("PROPOSAL_NOT_FOUND", "Proposal not found");
        }
        return proposal;
    }

    private void rejectPending(UUID threadId) {
        if (proposals.findPendingByThread(threadId).isPresent()) {
            throw new ConversationFailure("PROPOSAL_ALREADY_RESOLVED",
                    "Confirm or cancel the pending proposal first");
        }
    }

    private static void alreadyResolved() {
        throw new ConversationFailure("PROPOSAL_ALREADY_RESOLVED", "Proposal is already resolved");
    }
}
