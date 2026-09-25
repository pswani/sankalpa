package com.sankalpa.adapter.config;

import com.sankalpa.application.conversation.ConversationUseCases;
import com.sankalpa.application.conversation.Proposal;
import com.sankalpa.domain.ActionType;
import com.sankalpa.domain.SankalpaId;
import com.sankalpa.domain.commitment.PeriodUnit;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.support.TransactionTemplate;

import java.time.LocalDate;
import java.time.LocalDateTime;
import java.util.List;
import java.util.UUID;
import java.util.function.Supplier;

/** Owns the outer transaction that includes proposal resolution and the joined domain command. */
public final class TransactionalConversationUseCases implements ConversationUseCases {
    private final ConversationUseCases delegate;
    private final TransactionTemplate transaction;

    public TransactionalConversationUseCases(ConversationUseCases delegate,
                                             PlatformTransactionManager manager) {
        this.delegate = delegate;
        this.transaction = new TransactionTemplate(manager);
    }

    private <T> T inTransaction(Supplier<T> action) {
        return transaction.execute(status -> action.get());
    }

    @Override public Proposal findBySourceRunId(UUID runId) {
        return inTransaction(() -> delegate.findBySourceRunId(runId));
    }

    @Override public Proposal findPendingByThread(UUID threadId) {
        return inTransaction(() -> delegate.findPendingByThread(threadId));
    }

    @Override
    public Proposal proposeSession(UUID threadId, UUID runId, SankalpaId sankalpaId,
                                   LocalDateTime occurredAt, String summary,
                                   List<SankalpaId> alternatives) {
        return inTransaction(() -> delegate.proposeSession(threadId, runId, sankalpaId,
                occurredAt, summary, alternatives));
    }

    @Override
    public Proposal proposeDeclaration(UUID threadId, UUID runId, String title, String description,
                                       ActionType actionType, LocalDate startDate,
                                       PeriodUnit periodUnit, int timesPerPeriod,
                                       Integer periodCount, List<String> inferredFields) {
        return inTransaction(() -> delegate.proposeDeclaration(threadId, runId, title, description,
                actionType, startDate, periodUnit, timesPerPeriod, periodCount, inferredFields));
    }

    @Override
    public Resolution confirm(UUID threadId, UUID proposalId, UUID confirmationId) {
        return inTransaction(() -> delegate.confirm(threadId, proposalId, confirmationId));
    }

    @Override
    public Resolution cancel(UUID threadId, UUID proposalId) {
        return inTransaction(() -> delegate.cancel(threadId, proposalId));
    }
}
