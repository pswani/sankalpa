package com.sankalpa.domain;

import com.sankalpa.domain.commitment.Commitment;
import com.sankalpa.domain.lifecycle.CompletionOutcome;
import com.sankalpa.domain.lifecycle.LifecycleState;
import com.sankalpa.domain.lifecycle.LifecycleTimeline;

import java.time.LocalDate;
import java.time.LocalDateTime;

public final class Sankalpa {
    private final SankalpaId id;
    private final Title title;
    private final Description description;
    private final ActionType actionType;
    private final Commitment commitment;
    private final LocalDateTime declaredAt;
    private final LifecycleTimeline lifecycle;
    private int version;

    private Sankalpa(SankalpaId id, Title title, Description description, ActionType actionType,
                     Commitment commitment, LocalDateTime declaredAt, LifecycleTimeline lifecycle, int version) {
        if (id == null || title == null || description == null || actionType == null
                || commitment == null || declaredAt == null || lifecycle == null) {
            throw new DomainException("INVALID_SANKALPA", "All sankalpa fields are required");
        }
        if (version < 0) {
            throw new DomainException("INVALID_SANKALPA", "Version cannot be negative");
        }
        this.id = id;
        this.title = title;
        this.description = description;
        this.actionType = actionType;
        this.commitment = commitment;
        this.declaredAt = declaredAt;
        this.lifecycle = lifecycle;
        this.version = version;
    }

    public static Sankalpa declare(SankalpaId id, Title title, Description description,
                                   ActionType actionType, Commitment commitment,
                                   LocalDateTime declaredAt, LocalDate today) {
        if (today == null) {
            throw new DomainException("INVALID_DECLARATION", "Declaration date is required");
        }
        if (commitment == null) {
            throw new DomainException("INVALID_DECLARATION", "Commitment is required");
        }
        if (commitment.startDate().isBefore(today.minusYears(1))) {
            throw new DomainException("START_DATE_TOO_FAR_IN_PAST",
                    "Start date cannot be more than one year in the past");
        }
        return new Sankalpa(id, title, description, actionType, commitment,
                declaredAt, new LifecycleTimeline(), 0);
    }

    public static Sankalpa reconstitute(SankalpaId id, Title title, Description description,
                                        ActionType actionType, Commitment commitment,
                                        LocalDateTime declaredAt, LifecycleTimeline lifecycle, int version) {
        return new Sankalpa(id, title, description, actionType, commitment, declaredAt, lifecycle, version);
    }

    public void begin(LocalDateTime effectiveAt, LocalDateTime recordedAt) {
        if (effectiveAt == null || recordedAt == null) {
            throw new DomainException("INVALID_LIFECYCLE_TRANSITION", "Transition times are required");
        }
        lifecycle.begin(commitment.startDate(), effectiveAt, recordedAt);
    }
    public void pause(LocalDateTime now) { transitionNow(LifecycleState.PAUSED, now); }
    public void resume(LocalDateTime now) {
        if (lifecycle.current() != LifecycleState.PAUSED) {
            throw new DomainException("INVALID_LIFECYCLE_TRANSITION",
                    "Cannot resume from " + lifecycle.current());
        }
        transitionNow(LifecycleState.IN_PROGRESS, now);
    }
    public void complete(CompletionOutcome outcome, LocalDateTime now) {
        if (outcome == null) {
            throw new DomainException("INVALID_COMPLETION_OUTCOME", "Completion outcome is required");
        }
        transitionNow(outcome == CompletionOutcome.SUCCESSFUL
                ? LifecycleState.COMPLETED_SUCCESSFULLY : LifecycleState.COMPLETED_UNSUCCESSFULLY, now);
    }
    public void stop(LocalDateTime now) { transitionNow(LifecycleState.STOPPED, now); }

    private void transitionNow(LifecycleState target, LocalDateTime now) {
        if (now == null) {
            throw new DomainException("INVALID_LIFECYCLE_TRANSITION", "Transition time is required");
        }
        lifecycle.transitionNow(target, now);
    }

    public Session logSession(SessionId sessionId, LocalDateTime occurredAt, LocalDateTime now) {
        if (sessionId == null || occurredAt == null || now == null) {
            throw new DomainException("INVALID_SESSION", "Session id and times are required");
        }
        if (occurredAt.isAfter(now)) {
            throw new DomainException("SESSION_IN_FUTURE", "Session cannot occur in the future");
        }
        if (!commitment.covers(occurredAt.toLocalDate())) {
            throw new DomainException("SESSION_OUTSIDE_COMMITMENT", "Session is outside commitment coverage");
        }
        if (!lifecycle.wasInProgressAt(occurredAt)) {
            throw new DomainException("SANKALPA_NOT_IN_PROGRESS", "Sankalpa was not in progress at that time");
        }
        return new Session(sessionId, id, occurredAt, now);
    }

    public SankalpaId id() { return id; }
    public Title title() { return title; }
    public Description description() { return description; }
    public ActionType actionType() { return actionType; }
    public Commitment commitment() { return commitment; }
    public LocalDateTime declaredAt() { return declaredAt; }
    public LifecycleTimeline lifecycle() { return lifecycle; }
    public int version() { return version; }
    public void markPersistedAtVersion(int version) { this.version = version; }
}
