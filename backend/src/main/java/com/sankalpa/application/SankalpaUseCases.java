package com.sankalpa.application;

import com.sankalpa.domain.ActionType;
import com.sankalpa.domain.Sankalpa;
import com.sankalpa.domain.SankalpaId;
import com.sankalpa.domain.Session;
import com.sankalpa.domain.SessionId;
import com.sankalpa.domain.commitment.PeriodOutcome;
import com.sankalpa.domain.commitment.PeriodUnit;
import com.sankalpa.domain.lifecycle.CompletionOutcome;
import com.sankalpa.domain.lifecycle.LifecycleTransition;

import java.time.LocalDate;
import java.time.LocalDateTime;
import java.util.List;

public interface SankalpaUseCases {
    Sankalpa declare(String title, String description, ActionType actionType, LocalDate startDate,
                     PeriodUnit periodUnit, int timesPerPeriod, Integer periodCount);
    List<Sankalpa> list();
    Sankalpa detail(SankalpaId id);
    Sankalpa begin(SankalpaId id, LocalDateTime effectiveAt);
    Sankalpa pause(SankalpaId id);
    Sankalpa resume(SankalpaId id);
    Sankalpa complete(SankalpaId id, CompletionOutcome outcome);
    Sankalpa stop(SankalpaId id);
    SessionLogResult logSession(SankalpaId id, SessionId sessionId, LocalDateTime occurredAt);
    void deleteSession(SankalpaId id, SessionId sessionId);
    PageResult<Session> sessions(SankalpaId id, LocalDate from, LocalDate until, int page, int size);
    List<LifecycleTransition> lifecycleHistory(SankalpaId id);
    List<PeriodOutcome> periodOutcomes(SankalpaId id, LocalDate from, LocalDate until);
    List<Sankalpa> list(PracticeContract contract);
    Sankalpa detail(SankalpaId id, PracticeContract contract);
    Sankalpa begin(SankalpaId id, LocalDateTime effectiveAt, PracticeContract contract);
    Sankalpa pause(SankalpaId id, PracticeContract contract);
    Sankalpa resume(SankalpaId id, PracticeContract contract);
    Sankalpa complete(SankalpaId id, CompletionOutcome outcome, PracticeContract contract);
    Sankalpa stop(SankalpaId id, PracticeContract contract);
    SessionLogResult logSession(SankalpaId id, SessionId sessionId, LocalDateTime occurredAt, PracticeContract contract);
    void deleteSession(SankalpaId id, SessionId sessionId, PracticeContract contract);
    List<LifecycleTransition> lifecycleHistory(SankalpaId id, PracticeContract contract);
    List<PeriodOutcome> periodOutcomes(SankalpaId id, LocalDate from, LocalDate until, PracticeContract contract);
    ExtensionResult extend(SankalpaId source, SankalpaId extension, int totalPeriodCount, PracticeContract contract);
    List<Sankalpa> linkedSeries(SankalpaId id, PracticeContract contract);
    long totalSessionCount(SankalpaId id);
    java.util.Map<SankalpaId, Long> totalSessionCounts(List<Sankalpa> vows);
    java.util.Map<SessionId, List<SankalpaId>> contributors(List<Session> facts);
    List<SankalpaId> contributors(Session session);
    CursorPage cursorSessions(SankalpaId target, LocalDate from, LocalDate until,
            SessionBoundary after, int size, PracticeContract contract);
    default Sankalpa correctBegin(SankalpaId id, java.util.UUID correctionId, LocalDateTime expected,
            LocalDateTime corrected, PracticeContract contract) { throw new UnsupportedOperationException(); }
    default Sankalpa lockForSessionBatch(SankalpaId id, PracticeContract contract) { return detail(id, contract); }
    <T> PracticeSnapshot<T> writeSnapshot(java.util.function.Supplier<T> query);
    <T> PracticeSnapshot<T> readSnapshot(Long expectedRevision, java.util.function.Supplier<T> query);
}
