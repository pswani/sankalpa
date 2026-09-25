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
    Resolution cancel(UUID threadId, UUID proposalId);
    record Resolution(Proposal proposal, boolean replay) {}
}
