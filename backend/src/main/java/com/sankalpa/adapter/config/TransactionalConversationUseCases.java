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
    private final UseCaseTransactions transactions;
    public TransactionalConversationUseCases(ConversationUseCases delegate, PlatformTransactionManager manager) {
        this(delegate, new JdbcUseCaseTransactions(manager));
    }
    public TransactionalConversationUseCases(ConversationUseCases delegate, UseCaseTransactions transactions) {
        this.delegate = delegate; this.transactions = transactions;
    }
    private <T> T inTransaction(Supplier<T> action) { return transactions.write(action); }

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

    @Override public Proposal proposeSessions(UUID thread, UUID run, SankalpaId id,
            com.sankalpa.application.conversation.BatchSessionPlan plan, com.sankalpa.application.PracticeContract contract) {
        return inTransaction(() -> delegate.proposeSessions(thread, run, id, plan, contract));
    }
    @Override public Proposal proposeSessions(UUID thread, UUID run, SankalpaId id,
            com.sankalpa.application.conversation.BatchSessionPlan plan, com.sankalpa.application.PracticeContract contract, boolean repairSupported) {
        return inTransaction(() -> delegate.proposeSessions(thread, run, id, plan, contract, repairSupported));
    }
    @Override public Resolution confirm(UUID thread, UUID proposal, UUID confirmation,
            com.sankalpa.application.PracticeContract contract, boolean batchSupported, boolean repairSupported) {
        try { return inTransaction(() -> delegate.confirm(thread, proposal, confirmation, contract, batchSupported, repairSupported)); }
        catch (com.sankalpa.application.conversation.BatchRejection failure) {
            return inTransaction(() -> delegate.rejectBatch(thread, proposal, confirmation, failure.code()));
        }
    }
    @Override public Resolution confirm(UUID thread, UUID proposal, UUID confirmation,
            com.sankalpa.application.PracticeContract contract, boolean batchSupported) {
        try { return inTransaction(() -> delegate.confirm(thread, proposal, confirmation, contract, batchSupported)); }
        catch (com.sankalpa.application.conversation.BatchRejection failure) {
            return inTransaction(() -> delegate.rejectBatch(thread, proposal, confirmation, failure.code()));
        }
    }
    @Override public Proposal proposeSession(UUID threadId,UUID runId,SankalpaId id,LocalDateTime at,String summary,
            List<SankalpaId> alternatives,com.sankalpa.application.PracticeContract contract) {
        return inTransaction(()->delegate.proposeSession(threadId,runId,id,at,summary,alternatives,contract));
    }
    @Override public Resolution confirm(UUID threadId,UUID proposalId,UUID confirmationId,com.sankalpa.application.PracticeContract contract) {
        return inTransaction(()->delegate.confirm(threadId,proposalId,confirmationId,contract));
    }

    @Override
    public Resolution cancel(UUID threadId, UUID proposalId) {
        return inTransaction(() -> delegate.cancel(threadId, proposalId));
    }
}
