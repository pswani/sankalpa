package com.sankalpa.adapter.in.web;

import com.sankalpa.application.SankalpaUseCases;
import com.sankalpa.application.SessionLogResult;
import com.sankalpa.adapter.out.persistence.ServiceInstanceIdentity;
import com.sankalpa.domain.SankalpaId;
import com.sankalpa.domain.SessionId;
import io.swagger.v3.oas.annotations.Operation;
import io.swagger.v3.oas.annotations.media.Content;
import io.swagger.v3.oas.annotations.media.Schema;
import io.swagger.v3.oas.annotations.responses.ApiResponse;
import io.swagger.v3.oas.annotations.responses.ApiResponses;
import io.swagger.v3.oas.annotations.tags.Tag;
import jakarta.validation.Valid;
import jakarta.validation.constraints.Max;
import jakarta.validation.constraints.Min;
import org.springframework.format.annotation.DateTimeFormat;
import org.springframework.http.MediaType;
import org.springframework.http.ResponseEntity;
import org.springframework.validation.annotation.Validated;
import org.springframework.web.bind.annotation.*;
import org.springframework.web.servlet.support.ServletUriComponentsBuilder;

import java.net.URI;
import java.time.LocalDate;
import java.util.List;
import java.util.UUID;

import static com.sankalpa.adapter.in.web.ApiModels.*;

@RestController
@RequestMapping(value = "/api/v1/sankalpas", produces = MediaType.APPLICATION_JSON_VALUE)
@Tag(name = "Sankalpas", description = "Declare and track commitments")
@Validated
public class SankalpaController {
    private final SankalpaUseCases service;
    private final ServiceInstanceIdentity serviceIdentity;

    public SankalpaController(SankalpaUseCases service, ServiceInstanceIdentity serviceIdentity) {
        this.service = service;
        this.serviceIdentity = serviceIdentity;
    }

    @PostMapping
    @Operation(summary = "Declare a sankalpa",
            description = "Creates a declaration in NOT_STARTED. Local dates and times use the configured application timezone.")
    @ApiResponses({
            @ApiResponse(responseCode = "201", description = "Declared"),
            @ApiResponse(responseCode = "400", description = "Malformed or invalid request",
                    content = @Content(mediaType = MediaType.APPLICATION_PROBLEM_JSON_VALUE,
                            schema = @Schema(implementation = ApiProblemResponse.class))),
            @ApiResponse(responseCode = "422", description = "Declaration violates a domain rule",
                    content = @Content(mediaType = MediaType.APPLICATION_PROBLEM_JSON_VALUE,
                            schema = @Schema(implementation = ApiProblemResponse.class)))
    })
    public ResponseEntity<SankalpaResponse> declare(@Valid @RequestBody DeclareRequest request) {
        SankalpaResponse response = SankalpaResponse.from(service.declare(
                request.title(), request.description(), request.actionType(), request.startDate(),
                request.periodUnit(), request.timesPerPeriod(), request.periodCount()));
        URI location = ServletUriComponentsBuilder.fromCurrentRequest().path("/{id}")
                .buildAndExpand(response.id()).toUri();
        return ResponseEntity.created(location).body(response);
    }

    @GetMapping
    @Operation(summary = "List sankalpas", description = "Returns declarations ordered by declaredAt descending.")
    @ApiResponse(responseCode = "200", description = "Declarations returned")
    public List<SankalpaResponse> list() {
        return service.list().stream().map(SankalpaResponse::from).toList();
    }

    @GetMapping("/{id}")
    @Operation(summary = "Get sankalpa detail")
    @ApiResponses({
            @ApiResponse(responseCode = "200", description = "Detail returned"),
            @ApiResponse(responseCode = "400", description = "Malformed id",
                    content = @Content(mediaType = MediaType.APPLICATION_PROBLEM_JSON_VALUE,
                            schema = @Schema(implementation = ApiProblemResponse.class))),
            @ApiResponse(responseCode = "404", description = "Sankalpa not found",
                    content = @Content(mediaType = MediaType.APPLICATION_PROBLEM_JSON_VALUE,
                            schema = @Schema(implementation = ApiProblemResponse.class)))
    })
    public SankalpaResponse detail(@PathVariable String id) {
        return SankalpaResponse.from(service.detail(SankalpaId.parse(id)));
    }

    @PostMapping("/{id}/begin")
    @Operation(summary = "Begin, optionally with a past effective time",
            description = "effectiveAt is interpreted in the configured application timezone; recordedAt always comes from the server clock.")
    @ApiResponses({
            @ApiResponse(responseCode = "200", description = "Sankalpa began"),
            @ApiResponse(responseCode = "400", description = "Malformed request",
                    content = @Content(mediaType = MediaType.APPLICATION_PROBLEM_JSON_VALUE,
                            schema = @Schema(implementation = ApiProblemResponse.class))),
            @ApiResponse(responseCode = "404", description = "Sankalpa not found",
                    content = @Content(mediaType = MediaType.APPLICATION_PROBLEM_JSON_VALUE,
                            schema = @Schema(implementation = ApiProblemResponse.class))),
            @ApiResponse(responseCode = "409", description = "Concurrent modification",
                    content = @Content(mediaType = MediaType.APPLICATION_PROBLEM_JSON_VALUE,
                            schema = @Schema(implementation = ApiProblemResponse.class))),
            @ApiResponse(responseCode = "422", description = "Invalid lifecycle transition",
                    content = @Content(mediaType = MediaType.APPLICATION_PROBLEM_JSON_VALUE,
                            schema = @Schema(implementation = ApiProblemResponse.class)))
    })
    public SankalpaResponse begin(@PathVariable String id,
                                  @Valid @RequestBody(required = false) BeginRequest request) {
        return SankalpaResponse.from(service.begin(SankalpaId.parse(id),
                request == null ? null : request.effectiveAt()));
    }

    @PostMapping("/{id}/pause")
    @Operation(summary = "Pause now")
    @LifecycleCommandResponses
    public SankalpaResponse pause(@PathVariable String id) {
        return SankalpaResponse.from(service.pause(SankalpaId.parse(id)));
    }

    @PostMapping("/{id}/resume")
    @Operation(summary = "Resume now")
    @LifecycleCommandResponses
    public SankalpaResponse resume(@PathVariable String id) {
        return SankalpaResponse.from(service.resume(SankalpaId.parse(id)));
    }

    @PostMapping("/{id}/complete")
    @Operation(summary = "Complete successfully or unsuccessfully now")
    @LifecycleCommandResponses
    public SankalpaResponse complete(@PathVariable String id,
                                     @Valid @RequestBody CompleteRequest request) {
        return SankalpaResponse.from(service.complete(SankalpaId.parse(id), request.outcome()));
    }

    @PostMapping("/{id}/stop")
    @Operation(summary = "Stop now")
    @LifecycleCommandResponses
    public SankalpaResponse stop(@PathVariable String id) {
        return SankalpaResponse.from(service.stop(SankalpaId.parse(id)));
    }

    @PostMapping("/{id}/sessions")
    @Operation(summary = "Log a performed session",
            description = "Reliable clients send the same UUID in body id and Idempotency-Key, plus the expected Sankalpa-Service-Instance. Exact replays return the original session.")
    @ApiResponses({
            @ApiResponse(responseCode = "201", description = "Session first created"),
            @ApiResponse(responseCode = "200", description = "Exact replay returned"),
            @ApiResponse(responseCode = "400", description = "Malformed request",
                    content = @Content(mediaType = MediaType.APPLICATION_PROBLEM_JSON_VALUE,
                            schema = @Schema(implementation = ApiProblemResponse.class))),
            @ApiResponse(responseCode = "404", description = "Sankalpa not found",
                    content = @Content(mediaType = MediaType.APPLICATION_PROBLEM_JSON_VALUE,
                            schema = @Schema(implementation = ApiProblemResponse.class))),
            @ApiResponse(responseCode = "409", description = "Concurrent modification",
                    content = @Content(mediaType = MediaType.APPLICATION_PROBLEM_JSON_VALUE,
                            schema = @Schema(implementation = ApiProblemResponse.class))),
            @ApiResponse(responseCode = "410", description = "This session identity was permanently deleted",
                    content = @Content(mediaType = MediaType.APPLICATION_PROBLEM_JSON_VALUE,
                            schema = @Schema(implementation = ApiProblemResponse.class))),
            @ApiResponse(responseCode = "422", description = "Session is not loggable",
                    content = @Content(mediaType = MediaType.APPLICATION_PROBLEM_JSON_VALUE,
                            schema = @Schema(implementation = ApiProblemResponse.class)))
    })
    public ResponseEntity<SessionResponse> logSession(
            @PathVariable String id,
            @RequestHeader(name = "Idempotency-Key", required = false) String idempotencyKey,
            @RequestHeader(name = "Sankalpa-Service-Instance", required = false) String expectedService,
            @Valid @RequestBody LogSessionRequest request) {
        SessionId sessionId = resolveSessionId(request.id(), idempotencyKey, expectedService);
        SessionLogResult result = service.logSession(
                SankalpaId.parse(id), sessionId, request.occurredAt());
        return ResponseEntity.status(result.created() ? 201 : 200)
                .body(SessionResponse.from(result.session()));
    }

    @DeleteMapping("/{id}/sessions/{sessionId}")
    @Operation(summary = "Permanently delete a session",
            description = "Idempotently deletes or reserves the exact session identity. The expected persistent service instance is required.")
    @ApiResponses({
            @ApiResponse(responseCode = "204", description = "Session deleted or deletion already reserved"),
            @ApiResponse(responseCode = "400", description = "Malformed request",
                    content = @Content(mediaType = MediaType.APPLICATION_PROBLEM_JSON_VALUE,
                            schema = @Schema(implementation = ApiProblemResponse.class))),
            @ApiResponse(responseCode = "404", description = "Sankalpa not found",
                    content = @Content(mediaType = MediaType.APPLICATION_PROBLEM_JSON_VALUE,
                            schema = @Schema(implementation = ApiProblemResponse.class))),
            @ApiResponse(responseCode = "409", description = "Identity owner or service instance conflicts",
                    content = @Content(mediaType = MediaType.APPLICATION_PROBLEM_JSON_VALUE,
                            schema = @Schema(implementation = ApiProblemResponse.class)))
    })
    public ResponseEntity<Void> deleteSession(
            @PathVariable String id,
            @PathVariable String sessionId,
            @RequestHeader(name = "Sankalpa-Service-Instance") String expectedService) {
        serviceIdentity.require(UUID.fromString(expectedService));
        service.deleteSession(SankalpaId.parse(id), SessionId.parse(sessionId));
        return ResponseEntity.noContent().build();
    }

    private SessionId resolveSessionId(UUID bodyId, String headerId, String expectedService) {
        UUID parsedHeader = headerId == null || headerId.isBlank()
                ? null : UUID.fromString(headerId);
        if (bodyId == null && parsedHeader == null) {
            return SessionId.newId();
        }
        if (bodyId != null && parsedHeader != null && !bodyId.equals(parsedHeader)) {
            throw new IllegalArgumentException("Body id and Idempotency-Key must match");
        }
        if (expectedService == null || expectedService.isBlank()) {
            throw new IllegalArgumentException("Sankalpa-Service-Instance is required");
        }
        serviceIdentity.require(UUID.fromString(expectedService));
        return new SessionId(bodyId != null ? bodyId : parsedHeader);
    }

    @GetMapping("/{id}/sessions")
    @Operation(summary = "Get paginated session history",
            description = "Returns sessions ordered by occurredAt descending, then id descending. from and until must be supplied together when filtering.")
    @ApiResponses({
            @ApiResponse(responseCode = "200", description = "Session page returned"),
            @ApiResponse(responseCode = "400", description = "Malformed id, range, or pagination",
                    content = @Content(mediaType = MediaType.APPLICATION_PROBLEM_JSON_VALUE,
                            schema = @Schema(implementation = ApiProblemResponse.class))),
            @ApiResponse(responseCode = "404", description = "Sankalpa not found",
                    content = @Content(mediaType = MediaType.APPLICATION_PROBLEM_JSON_VALUE,
                            schema = @Schema(implementation = ApiProblemResponse.class)))
    })
    public SessionPageResponse sessions(
            @PathVariable String id,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate from,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate until,
            @RequestParam(defaultValue = "0") @Min(0) int page,
            @RequestParam(defaultValue = "50") @Min(1) @Max(200) int size) {
        return SessionPageResponse.from(service.sessions(SankalpaId.parse(id), from, until, page, size));
    }

    @GetMapping("/{id}/lifecycle-history")
    @Operation(summary = "Get lifecycle audit history",
            description = "Returns transitions in recorded sequence, oldest first.")
    @ApiResponses({
            @ApiResponse(responseCode = "200", description = "History returned"),
            @ApiResponse(responseCode = "400", description = "Malformed id",
                    content = @Content(mediaType = MediaType.APPLICATION_PROBLEM_JSON_VALUE,
                            schema = @Schema(implementation = ApiProblemResponse.class))),
            @ApiResponse(responseCode = "404", description = "Sankalpa not found",
                    content = @Content(mediaType = MediaType.APPLICATION_PROBLEM_JSON_VALUE,
                            schema = @Schema(implementation = ApiProblemResponse.class)))
    })
    public List<LifecycleTransitionResponse> lifecycleHistory(@PathVariable String id) {
        return service.lifecycleHistory(SankalpaId.parse(id)).stream()
                .map(LifecycleTransitionResponse::from).toList();
    }

    @GetMapping("/{id}/period-outcomes")
    @Operation(summary = "Get derived outcomes for windows whose start falls in the date range",
            description = "from and until are inclusive local dates in the configured application timezone. At most 3650 windows may be selected.")
    @ApiResponses({
            @ApiResponse(responseCode = "200", description = "Outcomes returned"),
            @ApiResponse(responseCode = "400", description = "Malformed id, invalid range, or range selecting more than 3650 windows",
                    content = @Content(mediaType = MediaType.APPLICATION_PROBLEM_JSON_VALUE,
                            schema = @Schema(implementation = ApiProblemResponse.class))),
            @ApiResponse(responseCode = "404", description = "Sankalpa not found",
                    content = @Content(mediaType = MediaType.APPLICATION_PROBLEM_JSON_VALUE,
                            schema = @Schema(implementation = ApiProblemResponse.class)))
    })
    public List<PeriodOutcomeResponse> periodOutcomes(
            @PathVariable String id,
            @RequestParam @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate from,
            @RequestParam @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate until) {
        return service.periodOutcomes(SankalpaId.parse(id), from, until).stream()
                .map(PeriodOutcomeResponse::from).toList();
    }
}
