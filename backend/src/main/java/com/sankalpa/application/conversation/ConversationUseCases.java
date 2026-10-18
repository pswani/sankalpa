package com.sankalpa.application.conversation;

import com.sankalpa.domain.ActionType;
import com.sankalpa.domain.SankalpaId;
import com.sankalpa.domain.commitment.PeriodUnit;

import java.time.LocalDate;
import java.time.LocalDateTime;
import java.util.List;
import java.util.UUID;

public interface ConversationUseCases {
    Proposal findBySourceRunId(UUID runId);
    Proposal findPendingByThread(UUID threadId);
    Proposal proposeSession(UUID threadId, UUID runId, SankalpaId sankalpaId,
                            LocalDateTime occurredAt, String summary,
                            List<SankalpaId> alternatives);
    Proposal proposeDeclaration(UUID threadId, UUID runId, String title, String description,
                                ActionType actionType, LocalDate startDate, PeriodUnit periodUnit,
                                int timesPerPeriod, Integer periodCount, List<String> inferredFields);
    Resolution confirm(UUID threadId, UUID proposalId, UUID confirmationId);
    Proposal proposeSession(UUID threadId, UUID runId, SankalpaId id, LocalDateTime at, String summary,
            List<SankalpaId> alternatives, com.sankalpa.application.PracticeContract contract);
    Resolution confirm(UUID threadId, UUID proposalId, UUID confirmationId, com.sankalpa.application.PracticeContract contract);
    Resolution cancel(UUID threadId, UUID proposalId);
    default Proposal proposeSessions(UUID thread, UUID run, SankalpaId id, BatchSessionPlan plan,
            com.sankalpa.application.PracticeContract contract) { throw new UnsupportedOperationException(); }
    default Resolution confirm(UUID thread, UUID proposal, UUID confirmation,
            com.sankalpa.application.PracticeContract contract, boolean batchSupported) {
        return confirm(thread, proposal, confirmation, contract);
    }
    default Resolution rejectBatch(UUID thread, UUID proposal, UUID confirmation, String code) {
        throw new UnsupportedOperationException();
    }
    record Resolution(Proposal proposal, boolean replay) {}
}
