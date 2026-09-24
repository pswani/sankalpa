package com.sankalpa.adapter.config;

import com.sankalpa.application.SankalpaUseCases;
import com.sankalpa.application.PageResult;
import com.sankalpa.application.SessionIdentityClaimConflictException;
import com.sankalpa.application.SessionLogResult;
import com.sankalpa.domain.ActionType;
import com.sankalpa.domain.Sankalpa;
import com.sankalpa.domain.SankalpaId;
import com.sankalpa.domain.Session;
import com.sankalpa.domain.SessionId;
import com.sankalpa.domain.commitment.PeriodOutcome;
import com.sankalpa.domain.commitment.PeriodUnit;
import com.sankalpa.domain.lifecycle.CompletionOutcome;
import com.sankalpa.domain.lifecycle.LifecycleTransition;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.support.TransactionTemplate;

import java.time.LocalDate;
import java.time.LocalDateTime;
import java.util.List;
import java.util.function.Supplier;

/** Spring transaction adapter around framework-free application use cases. */
public final class TransactionalSankalpaUseCases implements SankalpaUseCases {
    private final SankalpaUseCases delegate;
    private final TransactionTemplate write;
    private final TransactionTemplate read;

    public TransactionalSankalpaUseCases(SankalpaUseCases delegate, PlatformTransactionManager manager) {
        this.delegate = delegate;
        this.write = new TransactionTemplate(manager);
        this.read = new TransactionTemplate(manager);
        // SQLite does not support changing JDBC read-only mode after connection creation.
        // Reads still get a transaction boundary, without the unsupported driver hint.
    }

    private <T> T writing(Supplier<T> action) { return write.execute(status -> action.get()); }
    private <T> T reading(Supplier<T> action) { return read.execute(status -> action.get()); }

    @Override
    public Sankalpa declare(String title, String description, ActionType actionType, LocalDate startDate,
                            PeriodUnit periodUnit, int timesPerPeriod, Integer periodCount) {
        return writing(() -> delegate.declare(title, description, actionType, startDate,
                periodUnit, timesPerPeriod, periodCount));
    }

    @Override public List<Sankalpa> list() { return reading(delegate::list); }
    @Override public Sankalpa detail(SankalpaId id) { return reading(() -> delegate.detail(id)); }
    @Override public Sankalpa begin(SankalpaId id, LocalDateTime effectiveAt) {
        return writing(() -> delegate.begin(id, effectiveAt));
    }
    @Override public Sankalpa pause(SankalpaId id) { return writing(() -> delegate.pause(id)); }
    @Override public Sankalpa resume(SankalpaId id) { return writing(() -> delegate.resume(id)); }
    @Override public Sankalpa complete(SankalpaId id, CompletionOutcome outcome) {
        return writing(() -> delegate.complete(id, outcome));
    }
    @Override public Sankalpa stop(SankalpaId id) { return writing(() -> delegate.stop(id)); }
    @Override public SessionLogResult logSession(SankalpaId id, SessionId sessionId,
                                                  LocalDateTime occurredAt) {
        return identityWriting(() -> delegate.logSession(id, sessionId, occurredAt));
    }
    @Override public void deleteSession(SankalpaId id, SessionId sessionId) {
        identityWriting(() -> {
            delegate.deleteSession(id, sessionId);
            return null;
        });
    }
    @Override public PageResult<Session> sessions(SankalpaId id, LocalDate from, LocalDate until,
                                                   int page, int size) {
        return reading(() -> delegate.sessions(id, from, until, page, size));
    }
    @Override public List<LifecycleTransition> lifecycleHistory(SankalpaId id) {
        return reading(() -> delegate.lifecycleHistory(id));
    }
    @Override public List<PeriodOutcome> periodOutcomes(SankalpaId id, LocalDate from, LocalDate until) {
        return reading(() -> delegate.periodOutcomes(id, from, until));
    }

    private <T> T identityWriting(Supplier<T> action) {
        try {
            return writing(action);
        } catch (SessionIdentityClaimConflictException conflict) {
            return writing(action);
        }
    }
}
