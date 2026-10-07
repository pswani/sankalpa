package com.sankalpa.application.conversation;

import com.sankalpa.domain.ActionType;
import com.sankalpa.domain.SankalpaId;
import com.sankalpa.domain.SessionId;
import com.sankalpa.domain.commitment.PeriodUnit;

import java.time.LocalDate;
import java.time.LocalDateTime;
import java.util.List;
import java.util.UUID;

public record Proposal(
        UUID id, UUID threadId, UUID sourceRunId, Kind kind, int schemaVersion,
        Payload payload, Status status, UUID confirmationId, UUID resultResourceId,
        String failureCode, LocalDateTime createdAt, LocalDateTime expiresAt,
        LocalDateTime resolvedAt) {
    public static final int SCHEMA_VERSION = 1;

    public enum Kind { LOG_SESSION, DECLARE_SANKALPA }
    public enum Status { PENDING, EXECUTED, CANCELLED, EXPIRED, REJECTED }

    public sealed interface Payload permits LogSessionPayload, DeclareSankalpaPayload {}

    public record LogSessionPayload(SessionId sessionId, SankalpaId sankalpaId,
                                    String sankalpaTitle, LocalDateTime occurredAt,
                                    String userSummary) implements Payload {}

    public record DeclareSankalpaPayload(String title, String description, ActionType actionType,
                                         LocalDate startDate, PeriodUnit periodUnit,
                                         int timesPerPeriod, Integer periodCount,
                                         List<String> inferredFields) implements Payload {
        public DeclareSankalpaPayload {
            inferredFields = List.copyOf(inferredFields);
        }
    }

    public Proposal resolve(Status finalStatus, UUID confirmation, UUID result,
                            String failure, LocalDateTime now) {
        return new Proposal(id, threadId, sourceRunId, kind, schemaVersion, payload, finalStatus,
                confirmation, result, failure, createdAt, expiresAt, now);
    }
}
