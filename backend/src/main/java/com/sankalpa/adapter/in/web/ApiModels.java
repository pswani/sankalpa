package com.sankalpa.adapter.in.web;

import com.sankalpa.application.PageResult;
import com.sankalpa.domain.ActionType;
import com.sankalpa.domain.Sankalpa;
import com.sankalpa.domain.Session;
import com.sankalpa.domain.commitment.Commitment;
import com.sankalpa.domain.commitment.PeriodOutcome;
import com.sankalpa.domain.commitment.PeriodStanding;
import com.sankalpa.domain.commitment.PeriodUnit;
import com.sankalpa.domain.lifecycle.CompletionOutcome;
import com.sankalpa.domain.lifecycle.LifecycleState;
import com.sankalpa.domain.lifecycle.LifecycleTransition;
import jakarta.validation.constraints.Min;
import jakarta.validation.constraints.Max;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Size;
import io.swagger.v3.oas.annotations.media.Schema;

import java.net.URI;
import java.time.LocalDate;
import java.time.LocalDateTime;
import java.util.List;
import java.util.Map;
import java.util.UUID;

public final class ApiModels {
    private ApiModels() {}

    public record DeclareRequest(
            @NotBlank @Size(max = 200)
            @Schema(example = "Vipassana", description = "Non-blank declaration title") String title,
            @Schema(example = "Sit for 45 minutes") String description,
            @NotNull @Schema(example = "MEDITATION") ActionType actionType,
            @NotNull @Schema(example = "2026-06-01") LocalDate startDate,
            @NotNull @Schema(example = "DAY") PeriodUnit periodUnit,
            @Min(1) @Max(Commitment.MAX_TIMES_PER_PERIOD)
            @Schema(example = "2", minimum = "1", maximum = "99") int timesPerPeriod,
            @Min(1) @Max(Commitment.MAX_PERIOD_COUNT)
            @Schema(example = "30", minimum = "1", maximum = "3650",
                    types = {"integer", "null"}, format = "int32",
                    description = "Whole-number duration in period units; omit for an indefinite commitment")
            Integer periodCount
    ) {}

    public record BeginRequest(
            @Schema(example = "2026-06-01T08:00:00", types = {"string", "null"}, format = "date-time",
                    description = "Optional past effective time, interpreted in the configured application timezone")
            LocalDateTime effectiveAt) {}
    public record CompleteRequest(
            @NotNull @Schema(example = "SUCCESSFUL") CompletionOutcome outcome) {}
    public record LogSessionRequest(
            @Schema(example = "720de829-5075-4f0e-94fa-444f851af73e",
                    types = {"string", "null"}, format = "uuid",
                    description = "Stable client session identity; legacy clients may omit during rollout")
            UUID id,
            @NotNull @Schema(example = "2026-06-01T08:00:00",
                    description = "Past occurrence time, interpreted in the configured application timezone")
            LocalDateTime occurredAt) {}

    public record CapabilitiesResponse(int sessionCommandIdentity, UUID serviceInstanceId,
                                       AssistantCapability assistant) {}
    public record AssistantCapability(boolean enabled, String aguiProfile,
                                      int maxMessages, int maxEventBytes,
                                      int maxRequestBytes, boolean authenticationRequired) {}

    public record SankalpaResponse(
            UUID id,
            String title,
            String description,
            ActionType actionType,
            LocalDate startDate,
            @Schema(types = {"string", "null"}, format = "date",
                    description = "Inclusive derived end date; null for an indefinite commitment")
            LocalDate endDate,
            PeriodUnit periodUnit,
            int timesPerPeriod,
            @Schema(types = {"integer", "null"}, format = "int32",
                    description = "Duration in period units; null for an indefinite commitment")
            Integer periodCount,
            LifecycleState lifecycleState,
            LocalDateTime declaredAt
    ) {
        public static SankalpaResponse from(Sankalpa value) {
            return new SankalpaResponse(value.id().value(), value.title().value(),
                    value.description().value(), value.actionType(), value.commitment().startDate(),
                    value.commitment().endDate().orElse(null), value.commitment().periodUnit(),
                    value.commitment().timesPerPeriod(), value.commitment().periodCount(),
                    value.lifecycle().current(), value.declaredAt());
        }
    }

    public record SessionResponse(UUID id, UUID sankalpaId,
                                  @Schema(description = "Interpreted in the configured application timezone")
                                  LocalDateTime occurredAt,
                                  @Schema(description = "Server time in the configured application timezone")
                                  LocalDateTime loggedAt) {
        public static SessionResponse from(Session value) {
            return new SessionResponse(value.id().value(), value.sankalpaId().value(),
                    value.occurredAt(), value.loggedAt());
        }
    }

    public record SessionPageResponse(
            List<SessionResponse> content,
            int page,
            int size,
            long totalElements,
            long totalPages
    ) {
        public static SessionPageResponse from(PageResult<Session> value) {
            return new SessionPageResponse(value.content().stream().map(SessionResponse::from).toList(),
                    value.page(), value.size(), value.totalElements(), value.totalPages());
        }
    }

    public record LifecycleTransitionResponse(
            LifecycleState from,
            LifecycleState to,
            LocalDateTime effectiveAt,
            LocalDateTime recordedAt
    ) {
        public static LifecycleTransitionResponse from(LifecycleTransition value) {
            return new LifecycleTransitionResponse(value.from(), value.to(),
                    value.effectiveAt(), value.recordedAt());
        }
    }

    public record PeriodOutcomeResponse(
            int periodIndex,
            LocalDate startDate,
            LocalDate endDate,
            int required,
            int performed,
            int missed,
            PeriodStanding standing
    ) {
        public static PeriodOutcomeResponse from(PeriodOutcome value) {
            return new PeriodOutcomeResponse(value.window().index(), value.window().start(),
                    value.window().end(), value.required(), value.performed(), value.missed(),
                    value.standing());
        }
    }

    @Schema(name = "ApiProblem", description = "RFC 9457 problem details with a stable application code")
    public record ApiProblemResponse(
            URI type,
            String title,
            int status,
            String detail,
            @Schema(types = {"string", "null"}, format = "uri") URI instance,
            String code,
            @Schema(types = {"object", "null"}) Map<String, String> errors
    ) {}
}
