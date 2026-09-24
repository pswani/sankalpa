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
        sankalpas.save(result);
        return result;
    }

    @Override
    public List<Sankalpa> list() { return sankalpas.findAll(); }

    @Override
    public Sankalpa detail(SankalpaId id) { return require(id); }

    @Override
    public Sankalpa begin(SankalpaId id, LocalDateTime effectiveAt) {
        Sankalpa sankalpa = require(id);
        LocalDateTime now = clock.now();
        sankalpa.begin(effectiveAt == null ? now : effectiveAt, now);
        sankalpas.save(sankalpa);
        return sankalpa;
    }

    @Override
    public Sankalpa pause(SankalpaId id) { return transition(id, Transition.PAUSE, null); }

    @Override
    public Sankalpa resume(SankalpaId id) { return transition(id, Transition.RESUME, null); }

    @Override
    public Sankalpa complete(SankalpaId id, CompletionOutcome outcome) {
        return transition(id, Transition.COMPLETE, outcome);
    }

    @Override
    public Sankalpa stop(SankalpaId id) { return transition(id, Transition.STOP, null); }

    private Sankalpa transition(SankalpaId id, Transition transition, CompletionOutcome outcome) {
        Sankalpa sankalpa = require(id);
        LocalDateTime now = clock.now();
        switch (transition) {
            case PAUSE -> sankalpa.pause(now);
            case RESUME -> sankalpa.resume(now);
            case COMPLETE -> sankalpa.complete(outcome, now);
            case STOP -> sankalpa.stop(now);
        }
        sankalpas.save(sankalpa);
        return sankalpa;
    }

    @Override
    public SessionLogResult logSession(SankalpaId id, SessionId sessionId,
                                       LocalDateTime occurredAt) {
        Sankalpa sankalpa = sankalpas.findByIdForUpdate(id)
                .orElseThrow(() -> new NotFoundException("Sankalpa " + id + " was not found"));

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

        Session session = sankalpa.logSession(sessionId, occurredAt, clock.now());
        sessions.claimIdentity(new SessionIdentity(sessionId, id, SessionIdentityState.ACTIVE));
        sessions.save(session);
        return new SessionLogResult(session, true);
    }

    @Override
    public void deleteSession(SankalpaId id, SessionId sessionId) {
        sankalpas.findByIdForUpdate(id)
                .orElseThrow(() -> new NotFoundException("Sankalpa " + id + " was not found"));

        var identity = sessions.findIdentity(sessionId);
        if (identity.isEmpty()) {
            sessions.claimIdentity(new SessionIdentity(sessionId, id, SessionIdentityState.DELETED));
            return;
        }
        SessionIdentity stored = identity.get();
        if (!stored.sankalpaId().equals(id)) {
            throw identityConflict(sessionId);
        }
        if (stored.state() == SessionIdentityState.DELETED) return;

        sessions.delete(sessionId);
        sessions.markDeleted(sessionId);
    }

    private SessionIdentityConflictException identityConflict(SessionId id) {
        return new SessionIdentityConflictException(
                "Session identity " + id + " is already bound to different values");
    }

    @Override
    public PageResult<Session> sessions(SankalpaId id, LocalDate from, LocalDate until,
                                        int page, int size) {
        require(id);
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
    public List<LifecycleTransition> lifecycleHistory(SankalpaId id) {
        return require(id).lifecycle().transitions();
    }

    @Override
    public List<PeriodOutcome> periodOutcomes(SankalpaId id, LocalDate from, LocalDate until) {
        Sankalpa sankalpa = require(id);
        List<PeriodWindow> windows = sankalpa.commitment().windowsStartingBetween(from, until);
        if (windows.isEmpty()) return List.of();
        LocalDate sessionFrom = windows.getFirst().start();
        LocalDate sessionUntil = windows.getLast().end();
        List<Session> relevantSessions = sessions.findForSankalpa(id, sessionFrom, sessionUntil);
        return outcomeCalculator.calculate(sankalpa.commitment(), sankalpa.lifecycle(),
                relevantSessions, from, until, clock.today());
    }

    private Sankalpa require(SankalpaId id) {
        return sankalpas.findById(id)
                .orElseThrow(() -> new NotFoundException("Sankalpa " + id + " was not found"));
    }

    private enum Transition { PAUSE, RESUME, COMPLETE, STOP }
}
