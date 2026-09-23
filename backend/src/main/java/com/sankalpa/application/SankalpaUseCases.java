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
    Sankalpa declare(SankalpaId id, String title, String description, ActionType actionType,
                     LocalDate startDate, PeriodUnit periodUnit, int timesPerPeriod,
                     Integer periodCount);
    default Sankalpa declare(String title, String description, ActionType actionType,
                             LocalDate startDate, PeriodUnit periodUnit, int timesPerPeriod,
                             Integer periodCount) {
        return declare(SankalpaId.newId(), title, description, actionType, startDate,
                periodUnit, timesPerPeriod, periodCount);
    }
    List<Sankalpa> list();
    Sankalpa detail(SankalpaId id);
    Sankalpa begin(SankalpaId id, LocalDateTime effectiveAt);
    Sankalpa pause(SankalpaId id);
    Sankalpa resume(SankalpaId id);
    Sankalpa complete(SankalpaId id, CompletionOutcome outcome);
    Sankalpa stop(SankalpaId id);
    Session logSession(SankalpaId id, SessionId sessionId, LocalDateTime occurredAt);
    default Session logSession(SankalpaId id, LocalDateTime occurredAt) {
        return logSession(id, SessionId.newId(), occurredAt);
    }
    PageResult<Session> sessions(SankalpaId id, LocalDate from, LocalDate until, int page, int size);
    List<LifecycleTransition> lifecycleHistory(SankalpaId id);
    List<PeriodOutcome> periodOutcomes(SankalpaId id, LocalDate from, LocalDate until);
}
