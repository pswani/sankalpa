package com.sankalpa.adapter.in.web;

import com.sankalpa.application.SankalpaUseCases;
import com.sankalpa.application.*;
import org.springframework.http.HttpHeaders;
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
    private final PracticeHttp http;

    public SankalpaController(SankalpaUseCases service, ServiceInstanceIdentity serviceIdentity, PracticeHttp http) {
        this.service = service;
        this.serviceIdentity = serviceIdentity;
        this.http = http;
    }

    @com.sankalpa.adapter.in.web.LinkedPracticeHeaders
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
    public ResponseEntity<SankalpaResponse> declare(@Valid @RequestBody DeclareRequest request,
            @io.swagger.v3.oas.annotations.Parameter(hidden=true) @RequestHeader HttpHeaders headers) {
        var response = http.write(headers, () -> http.vow(service.declare(request.title(), request.description(), request.actionType(),
                request.startDate(), request.periodUnit(), request.timesPerPeriod(), request.periodCount())), 201);
        return ResponseEntity.status(201).headers(response.getHeaders()).location(URI.create("/api/v1/sankalpas/" + response.getBody().id())).body(response.getBody());
    }

    @com.sankalpa.adapter.in.web.LinkedPracticeHeaders
    @GetMapping
    @Operation(summary = "List sankalpas", description = "Returns declarations ordered by declaredAt descending.")
    @ApiResponse(responseCode = "200", description = "Declarations returned")
    public ResponseEntity<List<SankalpaResponse>> list(@io.swagger.v3.oas.annotations.Parameter(hidden=true) @RequestHeader HttpHeaders headers) {
        return http.read(headers, () -> http.vows(service.list(http.contract(headers))));
    }

    @com.sankalpa.adapter.in.web.LinkedPracticeHeaders
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
    public ResponseEntity<SankalpaResponse> detail(@PathVariable String id,
            @io.swagger.v3.oas.annotations.Parameter(hidden=true) @RequestHeader HttpHeaders headers) {
        return http.read(headers, () -> http.vow(service.detail(SankalpaId.parse(id), http.contract(headers))));
    }

    @com.sankalpa.adapter.in.web.LinkedPracticeHeaders
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
    public ResponseEntity<SankalpaResponse> begin(@PathVariable String id,
                                  @Valid @RequestBody(required = false) BeginRequest request,
            @io.swagger.v3.oas.annotations.Parameter(hidden=true) @RequestHeader HttpHeaders headers) {
        return http.write(headers, () -> http.vow(service.begin(SankalpaId.parse(id),
                request == null ? null : request.effectiveAt(), http.contract(headers))), 200);
    }

    @com.sankalpa.adapter.in.web.LinkedPracticeHeaders
    @PostMapping("/{id}/pause")
    @Operation(summary = "Pause now")
    @LifecycleCommandResponses
    public ResponseEntity<SankalpaResponse> pause(@PathVariable String id,
            @io.swagger.v3.oas.annotations.Parameter(hidden=true) @RequestHeader HttpHeaders headers) {
        return http.write(headers, () -> http.vow(service.pause(SankalpaId.parse(id), http.contract(headers))), 200);
    }

    @com.sankalpa.adapter.in.web.LinkedPracticeHeaders
    @PostMapping("/{id}/resume")
    @Operation(summary = "Resume now")
    @LifecycleCommandResponses
    public ResponseEntity<SankalpaResponse> resume(@PathVariable String id,
            @io.swagger.v3.oas.annotations.Parameter(hidden=true) @RequestHeader HttpHeaders headers) {
        return http.write(headers, () -> http.vow(service.resume(SankalpaId.parse(id), http.contract(headers))), 200);
    }

    @com.sankalpa.adapter.in.web.LinkedPracticeHeaders
    @PostMapping("/{id}/complete")
    @Operation(summary = "Complete successfully or unsuccessfully now")
    @LifecycleCommandResponses
    public ResponseEntity<SankalpaResponse> complete(@PathVariable String id,
                                     @Valid @RequestBody CompleteRequest request,
            @io.swagger.v3.oas.annotations.Parameter(hidden=true) @RequestHeader HttpHeaders headers) {
        return http.write(headers, () -> http.vow(service.complete(SankalpaId.parse(id), request.outcome(), http.contract(headers))), 200);
    }

    @com.sankalpa.adapter.in.web.LinkedPracticeHeaders
    @PostMapping("/{id}/stop")
    @Operation(summary = "Stop now")
    @LifecycleCommandResponses
    public ResponseEntity<SankalpaResponse> stop(@PathVariable String id,
            @io.swagger.v3.oas.annotations.Parameter(hidden=true) @RequestHeader HttpHeaders headers) {
        return http.write(headers, () -> http.vow(service.stop(SankalpaId.parse(id), http.contract(headers))), 200);
    }

    @com.sankalpa.adapter.in.web.LinkedPracticeHeaders
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
            @Valid @RequestBody LogSessionRequest request,
            @io.swagger.v3.oas.annotations.Parameter(hidden=true) @RequestHeader HttpHeaders headers) {
        var contract=http.contract(headers);
        if(contract==PracticeContract.LINKED_V1 && (request.id()==null || idempotencyKey==null))
            throw new IllegalArgumentException("Linked logs require matching body/header identity");
        SessionId sessionId=resolveSessionId(request.id(),idempotencyKey,expectedService);
        var response=service.writeSnapshot(() -> {
            var result=service.logSession(SankalpaId.parse(id),sessionId,request.occurredAt(),contract);
            return new LoggedResponse(http.session(result.session()),result.created());
        });
        return http.response(new PracticeSnapshot<>(response.revision(),response.value().session()),response.value().created()?201:200);
    }

    @com.sankalpa.adapter.in.web.LinkedPracticeHeaders
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
            @RequestHeader(name = "Sankalpa-Service-Instance") String expectedService,
            @io.swagger.v3.oas.annotations.Parameter(hidden=true) @RequestHeader HttpHeaders headers) {
        serviceIdentity.require(UUID.fromString(expectedService));
        return http.write(headers, () -> { service.deleteSession(SankalpaId.parse(id),SessionId.parse(sessionId),http.contract(headers)); return null; }, 204);
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

    @com.sankalpa.adapter.in.web.LinkedPracticeHeaders
    @GetMapping("/{id}/sessions")
    @Operation(summary = "Get paginated session history",
            description = "Returns sessions ordered by occurredAt descending, then id descending. from and until must be supplied together when filtering.")
    @ApiResponses({
            @ApiResponse(responseCode = "200", description = "Session page returned", content=@Content(mediaType=MediaType.APPLICATION_JSON_VALUE,
                    schema=@Schema(oneOf={SessionPageResponse.class,CursorSessionPageResponse.class}))),
            @ApiResponse(responseCode = "400", description = "Malformed id, range, or pagination",
                    content = @Content(mediaType = MediaType.APPLICATION_PROBLEM_JSON_VALUE,
                            schema = @Schema(implementation = ApiProblemResponse.class))),
            @ApiResponse(responseCode = "404", description = "Sankalpa not found",
                    content = @Content(mediaType = MediaType.APPLICATION_PROBLEM_JSON_VALUE,
                            schema = @Schema(implementation = ApiProblemResponse.class)))
    })
    public ResponseEntity<?> sessions(
            @PathVariable String id,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate from,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate until,
            @RequestParam(defaultValue = "0") @Min(0) int page,
            @RequestParam(required = false) @Min(1) @Max(200) Integer size,
            @io.swagger.v3.oas.annotations.Parameter(hidden=true) @RequestHeader HttpHeaders headers,
            @RequestParam(required=false) String cursor) {
        if(headers.containsKey("Linked-Sankalpa-Version"))return http.page(headers,SankalpaId.parse(id),from,until,cursor,size == null ? 100 : size);
        return http.read(headers, () -> SessionPageResponse.from(service.sessions(SankalpaId.parse(id),from,until,page,size == null ? 50 : size)));
    }

    @com.sankalpa.adapter.in.web.LinkedPracticeHeaders
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
    public ResponseEntity<List<LifecycleTransitionResponse>> lifecycleHistory(@PathVariable String id,
            @io.swagger.v3.oas.annotations.Parameter(hidden=true) @RequestHeader HttpHeaders headers) {
        return http.read(headers, () -> http.history(service.detail(SankalpaId.parse(id),http.contract(headers))));
    }

    @com.sankalpa.adapter.in.web.LinkedPracticeHeaders
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
    public ResponseEntity<List<PeriodOutcomeResponse>> periodOutcomes(
            @PathVariable String id,
            @RequestParam @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate from,
            @RequestParam @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate until,
            @io.swagger.v3.oas.annotations.Parameter(hidden=true) @RequestHeader HttpHeaders headers) {
        return http.read(headers, () -> service.periodOutcomes(SankalpaId.parse(id),from,until,http.contract(headers)).stream().map(PeriodOutcomeResponse::from).toList());
    }
    private record LoggedResponse(SessionResponse session, boolean created) {}

    @io.swagger.v3.oas.annotations.Parameter(name="Idempotency-Key", in=io.swagger.v3.oas.annotations.enums.ParameterIn.HEADER, required=true, description="Must equal the body extension UUID")
    @com.sankalpa.adapter.in.web.LinkedPracticeHeaders
    @PostMapping("/{id}/extensions")
    @Operation(summary="Create a longer linked vow", description="Requires linked contract 1 and matching body/idempotency identity")
    @ApiResponses({@ApiResponse(responseCode="201",description="Created"), @ApiResponse(responseCode="200",description="Exact replay"),
            @ApiResponse(responseCode="409",description="Identity, child, or contract conflict"),@ApiResponse(responseCode="422",description="Not extendable")})
    public ResponseEntity<ExtensionResponse> extend(@PathVariable String id, @io.swagger.v3.oas.annotations.Parameter(hidden=true) @RequestHeader HttpHeaders headers,
            @Valid @RequestBody ExtendRequest request) {
        var contract=http.contract(headers);contract.requireLinked();
        if(!request.id().toString().equals(headers.getFirst("Idempotency-Key")))
            throw new PracticeException("INVALID_EXTENSION_REQUEST","Body identity must match Idempotency-Key");
        var snapshot=service.writeSnapshot(() -> {
            var result=service.extend(SankalpaId.parse(id),new SankalpaId(request.id()),request.totalPeriodCount(),contract);
            return new ExtensionResponse(result.created(),http.vow(result.sankalpa()),http.series(result.sankalpa().id()));
        });
        var response=http.response(snapshot,snapshot.value().created()?201:200);
        return ResponseEntity.status(response.getStatusCode()).headers(response.getHeaders())
                .location(URI.create("/api/v1/sankalpas/"+response.getBody().sankalpa().id())).body(response.getBody());
    }

    @com.sankalpa.adapter.in.web.LinkedPracticeHeaders
    @GetMapping("/{id}/linked-series")
    @Operation(summary="Get independently completable linked vows in duration order")
    public ResponseEntity<List<VowSnapshot>> linkedSeries(@PathVariable String id,@io.swagger.v3.oas.annotations.Parameter(hidden=true) @RequestHeader HttpHeaders headers) {
        http.contract(headers).requireLinked();
        return http.read(headers,()->http.series(SankalpaId.parse(id)));
    }
}
