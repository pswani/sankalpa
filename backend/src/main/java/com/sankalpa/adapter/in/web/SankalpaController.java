package com.sankalpa.adapter.in.web;

import com.sankalpa.application.SankalpaUseCases;
import com.sankalpa.application.SessionLogResult;
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

import static com.sankalpa.adapter.in.web.ApiModels.*;

@RestController
@RequestMapping(value = "/api/v1/sankalpas", produces = MediaType.APPLICATION_JSON_VALUE)
@Tag(name = "Sankalpas", description = "Declare and track commitments")
@Validated
public class SankalpaController {
    private final SankalpaUseCases service;

    public SankalpaController(SankalpaUseCases service) { this.service = service; }

    @PostMapping
    @Operation(summary = "Declare a sankalpa",
            description = "Creates a declaration in NOT_STARTED. Local dates and times use the configured application timezone.")
    @ApiResponses({
            @ApiResponse(responseCode = "201", description = "Declared"),
            @ApiResponse(responseCode = "400", description = "Malformed or invalid request",
                    content = @Content(mediaType = MediaType.APPLICATION_PROBLEM_JSON_VALUE,
                            schema = @Schema(implementation = ApiProblemResponse.class))),
            @ApiResponse(responseCode = "409", description = "Client id was already used for different values",
                    content = @Content(mediaType = MediaType.APPLICATION_PROBLEM_JSON_VALUE,
                            schema = @Schema(implementation = ApiProblemResponse.class))),
            @ApiResponse(responseCode = "422", description = "Declaration violates a domain rule",
                    content = @Content(mediaType = MediaType.APPLICATION_PROBLEM_JSON_VALUE,
                            schema = @Schema(implementation = ApiProblemResponse.class)))
    })
    public ResponseEntity<SankalpaResponse> declare(@Valid @RequestBody DeclareRequest request) {
        SankalpaResponse response = SankalpaResponse.from(service.declare(
                request.id() == null ? SankalpaId.newId() : new SankalpaId(request.id()),
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
            description = "occurredAt is interpreted in the configured application timezone. The response body identifies the created session.")
    @ApiResponses({
            @ApiResponse(responseCode = "201", description = "Session logged"),
            @ApiResponse(responseCode = "200", description = "Previously accepted session returned"),
            @ApiResponse(responseCode = "400", description = "Malformed request",
                    content = @Content(mediaType = MediaType.APPLICATION_PROBLEM_JSON_VALUE,
                            schema = @Schema(implementation = ApiProblemResponse.class))),
            @ApiResponse(responseCode = "404", description = "Sankalpa not found",
                    content = @Content(mediaType = MediaType.APPLICATION_PROBLEM_JSON_VALUE,
                            schema = @Schema(implementation = ApiProblemResponse.class))),
            @ApiResponse(responseCode = "409", description = "Concurrent modification or client-id conflict",
                    content = @Content(mediaType = MediaType.APPLICATION_PROBLEM_JSON_VALUE,
                            schema = @Schema(implementation = ApiProblemResponse.class))),
            @ApiResponse(responseCode = "410", description = "Session was permanently deleted",
                    content = @Content(mediaType = MediaType.APPLICATION_PROBLEM_JSON_VALUE,
                            schema = @Schema(implementation = ApiProblemResponse.class))),
            @ApiResponse(responseCode = "422", description = "Session is not loggable",
                    content = @Content(mediaType = MediaType.APPLICATION_PROBLEM_JSON_VALUE,
                            schema = @Schema(implementation = ApiProblemResponse.class)))
    })
    public ResponseEntity<SessionResponse> logSession(@PathVariable String id,
                                                       @RequestHeader(name = "Idempotency-Key", required = false)
                                                       String idempotencyKey,
                                                       @Valid @RequestBody LogSessionRequest request) {
        SessionId sessionId = sessionId(idempotencyKey, request);
        SessionLogResult result = service.logSessionResult(
                SankalpaId.parse(id), sessionId, request.occurredAt());
        return ResponseEntity.status(result.created() ? 201 : 200)
                .body(SessionResponse.from(result.session()));
    }

    @DeleteMapping("/{id}/sessions/{sessionId}")
    @Operation(summary = "Permanently delete a session",
            description = "Deletion is idempotent and prevents a delayed create with the same session identity.")
    @ApiResponses({
            @ApiResponse(responseCode = "204", description = "Session absent and protected from recreation"),
            @ApiResponse(responseCode = "400", description = "Malformed id",
                    content = @Content(mediaType = MediaType.APPLICATION_PROBLEM_JSON_VALUE,
                            schema = @Schema(implementation = ApiProblemResponse.class))),
            @ApiResponse(responseCode = "404", description = "Sankalpa not found",
                    content = @Content(mediaType = MediaType.APPLICATION_PROBLEM_JSON_VALUE,
                            schema = @Schema(implementation = ApiProblemResponse.class))),
            @ApiResponse(responseCode = "409", description = "Session identity belongs to another sankalpa",
                    content = @Content(mediaType = MediaType.APPLICATION_PROBLEM_JSON_VALUE,
                            schema = @Schema(implementation = ApiProblemResponse.class)))
    })
    public ResponseEntity<Void> deleteSession(
            @PathVariable String id, @PathVariable String sessionId) {
        service.deleteSession(SankalpaId.parse(id), SessionId.parse(sessionId));
        return ResponseEntity.noContent().build();
    }

    private SessionId sessionId(String idempotencyKey, LogSessionRequest request) {
        SessionId headerId = idempotencyKey == null ? null : SessionId.parse(idempotencyKey);
        SessionId bodyId = request.id() == null ? null : new SessionId(request.id());
        if (headerId != null && bodyId != null && !headerId.equals(bodyId)) {
            throw new IllegalArgumentException("Idempotency-Key and request id must match");
        }
        if (headerId != null) return headerId;
        if (bodyId != null) return bodyId;
        return SessionId.newId();
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
