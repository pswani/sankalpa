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

    public enum Kind { LOG_SESSION, DECLARE_SANKALPA, LOG_SESSIONS }
    public enum Status { PENDING, EXECUTED, CANCELLED, EXPIRED, REJECTED }

    public sealed interface Payload permits LogSessionPayload, DeclareSankalpaPayload, LogSessionsPayload {}

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

    public record BatchEntry(SessionId sessionId, LocalDateTime occurredAt) {}
    public record SkippedDay(LocalDate date, List<SessionId> contributionIds) {
        public SkippedDay { contributionIds = List.copyOf(contributionIds); }
    }
    public record LogSessionsPayload(SankalpaId sankalpaId, String sankalpaTitle, SankalpaId seriesId,
            com.sankalpa.application.PracticeContract contract, UUID serviceInstanceId, String timezone,
            BatchSessionPlan plan, long baseRevision, int requestedCount, List<BatchEntry> entries,
            List<SkippedDay> skippedDays, List<LocalDateTime> repeatWarnings) implements Payload {
        public LogSessionsPayload {
            entries = List.copyOf(entries); skippedDays = List.copyOf(skippedDays);
            repeatWarnings = List.copyOf(repeatWarnings);
        }
    }
    public record BatchResult(UUID sankalpaId, List<UUID> sessionIds, int createdCount, int skippedCount) {}
    public BatchResult batchResult() {
        if (status != Status.EXECUTED || !(payload instanceof LogSessionsPayload p)) return null;
        return new BatchResult(p.sankalpaId().value(), p.entries().stream().map(e -> e.sessionId().value()).toList(),
                p.entries().size(), p.skippedDays().size());
    }
    public static Class<? extends Payload> payloadType(Kind kind, int version) {
        if (version != (kind == Kind.LOG_SESSIONS ? 2 : SCHEMA_VERSION))
            throw new IllegalArgumentException("Unsupported proposal version");
        return switch (kind) {
            case LOG_SESSION -> LogSessionPayload.class;
            case DECLARE_SANKALPA -> DeclareSankalpaPayload.class;
            case LOG_SESSIONS -> LogSessionsPayload.class;
        };
    }

    public Proposal resolve(Status finalStatus, UUID confirmation, UUID result,
                            String failure, LocalDateTime now) {
        return new Proposal(id, threadId, sourceRunId, kind, schemaVersion, payload, finalStatus,
                confirmation, result, failure, createdAt, expiresAt, now);
    }
}
