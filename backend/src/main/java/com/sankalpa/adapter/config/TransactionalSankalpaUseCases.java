package com.sankalpa.adapter.config;

import com.sankalpa.application.*;
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
        this.read.setIsolationLevel(org.springframework.transaction.TransactionDefinition.ISOLATION_SERIALIZABLE);
        // SQLite does not support changing JDBC read-only mode after connection creation.
        // Reads still get a transaction boundary, without the unsupported driver hint.
    }

    private <T> T writing(Supplier<T> action) { return write.execute(status -> action.get()); }
    private <T> T reading(Supplier<T> action) { return read.execute(status -> action.get()); }

    @Override
    public Sankalpa declare(String title, String description, ActionType actionType, LocalDate startDate,
                            PeriodUnit periodUnit, int timesPerPeriod, Integer periodCount) {
        return identityWriting(() -> delegate.declare(title, description, actionType, startDate,
                periodUnit, timesPerPeriod, periodCount));
    }

    @Override public List<Sankalpa> list() { return reading(delegate::list); }
    @Override public Sankalpa detail(SankalpaId id) { return reading(() -> delegate.detail(id)); }
    @Override public Sankalpa begin(SankalpaId id, LocalDateTime effectiveAt) {
        return identityWriting(() -> delegate.begin(id, effectiveAt));
    }
    @Override public Sankalpa pause(SankalpaId id) { return identityWriting(() -> delegate.pause(id)); }
    @Override public Sankalpa resume(SankalpaId id) { return identityWriting(() -> delegate.resume(id)); }
    @Override public Sankalpa complete(SankalpaId id, CompletionOutcome outcome) {
        return identityWriting(() -> delegate.complete(id, outcome));
    }
    @Override public Sankalpa stop(SankalpaId id) { return identityWriting(() -> delegate.stop(id)); }
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

    @Override public List<Sankalpa> list(PracticeContract contract) { return reading(() -> delegate.list(contract)); }
    @Override public Sankalpa detail(SankalpaId id, PracticeContract contract) { return reading(() -> delegate.detail(id, contract)); }
    @Override public Sankalpa begin(SankalpaId id, LocalDateTime effectiveAt, PracticeContract contract) { return identityWriting(() -> delegate.begin(id, effectiveAt, contract)); }
    @Override public Sankalpa pause(SankalpaId id, PracticeContract contract) { return identityWriting(() -> delegate.pause(id, contract)); }
    @Override public Sankalpa resume(SankalpaId id, PracticeContract contract) { return identityWriting(() -> delegate.resume(id, contract)); }
    @Override public Sankalpa complete(SankalpaId id, CompletionOutcome outcome, PracticeContract contract) { return identityWriting(() -> delegate.complete(id, outcome, contract)); }
    @Override public Sankalpa stop(SankalpaId id, PracticeContract contract) { return identityWriting(() -> delegate.stop(id, contract)); }
    @Override public SessionLogResult logSession(SankalpaId id, SessionId sessionId, LocalDateTime occurredAt, PracticeContract contract) { return identityWriting(() -> delegate.logSession(id, sessionId, occurredAt, contract)); }
    @Override public void deleteSession(SankalpaId id, SessionId sessionId, PracticeContract contract) { identityWriting(() -> { delegate.deleteSession(id, sessionId, contract); return null; }); }
    @Override public List<LifecycleTransition> lifecycleHistory(SankalpaId id, PracticeContract contract) { return reading(() -> delegate.lifecycleHistory(id, contract)); }
    @Override public List<PeriodOutcome> periodOutcomes(SankalpaId id, LocalDate from, LocalDate until, PracticeContract contract) { return reading(() -> delegate.periodOutcomes(id, from, until, contract)); }
    @Override public ExtensionResult extend(SankalpaId source, SankalpaId extension, int count, PracticeContract contract) {
        return identityWriting(() -> delegate.extend(source, extension, count, contract));
    }
    @Override public List<Sankalpa> linkedSeries(SankalpaId id, PracticeContract contract) {
        return reading(() -> delegate.linkedSeries(id, contract));
    }
    @Override public long totalSessionCount(SankalpaId id) { return reading(() -> delegate.totalSessionCount(id)); }
    @Override public java.util.Map<SankalpaId, Long> totalSessionCounts(List<Sankalpa> vows) { return reading(() -> delegate.totalSessionCounts(vows)); }
    @Override public java.util.Map<SessionId, List<SankalpaId>> contributors(List<Session> facts) { return reading(() -> delegate.contributors(facts)); }
    @Override public List<SankalpaId> contributors(Session session) { return reading(() -> delegate.contributors(session)); }
    @Override public CursorPage cursorSessions(SankalpaId target, LocalDate from, LocalDate until,
            SessionBoundary after, int size, PracticeContract contract) {
        return reading(() -> delegate.cursorSessions(target, from, until, after, size, contract));
    }
    @Override public <T> PracticeSnapshot<T> readSnapshot(Long revision, Supplier<T> query) {
        return reading(() -> delegate.readSnapshot(revision, query));
    }

    @Override public <T> PracticeSnapshot<T> writeSnapshot(Supplier<T> query) {
        return identityWriting(() -> delegate.writeSnapshot(query));
    }

    private <T> T identityWriting(Supplier<T> action) {
        if (org.springframework.transaction.support.TransactionSynchronizationManager.isActualTransactionActive())
            return action.get();
        return PracticeTransactions.retry(() -> writing(action));
    }
}
