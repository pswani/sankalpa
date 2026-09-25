package com.sankalpa.adapter.in.conversation;

import com.fasterxml.jackson.databind.JsonNode;
import com.sankalpa.application.conversation.*;
import org.springframework.beans.factory.annotation.Qualifier;
import org.springframework.beans.factory.annotation.Value;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.http.MediaType;
import org.springframework.http.ResponseEntity;
import org.springframework.scheduling.concurrent.ThreadPoolTaskExecutor;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;
import org.springframework.web.servlet.mvc.method.annotation.SseEmitter;

import java.io.IOException;
import java.time.ZoneId;
import java.util.*;

import static com.sankalpa.adapter.in.conversation.AGUIModels.*;

@RestController
@RequestMapping("/api/v1/assistant")
public final class ConversationController {
    private static final Logger log = LoggerFactory.getLogger(ConversationController.class);
    public static final String AGUI_PROFILE = "ag-ui-sankalpa/1";
    private final ConversationCoordinator coordinator;
    private final ThreadPoolTaskExecutor executor;
    private final boolean enabled;
    private final ZoneId zone;

    public ConversationController(ConversationCoordinator coordinator,
            @Qualifier("assistantExecutor") ThreadPoolTaskExecutor executor,
            @Value("${sankalpa.assistant.enabled:false}") boolean enabled,
            @Value("${sankalpa.timezone}") String timezone) {
        this.coordinator = coordinator;
        this.executor = executor;
        this.enabled = enabled;
        this.zone = ZoneId.of(timezone);
    }

    @PostMapping(value = "/runs", consumes = MediaType.APPLICATION_JSON_VALUE,
            produces = MediaType.TEXT_EVENT_STREAM_VALUE)
    public ResponseEntity<SseEmitter> run(@RequestBody RunAgentInput wire) {
        if (!enabled) throw new ConversationFailure("ASSISTANT_DISABLED", "Assistant is disabled");
        ConversationCoordinator.RunInput input = validate(wire);
        SseEmitter emitter = new SseEmitter(35_000L);
        executor.execute(() -> stream(input, emitter));
        return ResponseEntity.ok().contentType(MediaType.TEXT_EVENT_STREAM).body(emitter);
    }

    private void stream(ConversationCoordinator.RunInput input, SseEmitter emitter) {
        try {
            send(emitter, event("RUN_STARTED", input, Map.of()));
            ConversationCoordinator.RunResult result = coordinator.run(input);
            for (var message : result.messages()) message(emitter, input, message);
            for (var effect : result.effects()) tool(emitter, input, effect);
            Map<String, Object> outcome = result.proposal() == null
                    ? Map.of("type", "success") : interrupt(result.proposal());
            send(emitter, event("RUN_FINISHED", input, Map.of("outcome", outcome)));
            emitter.complete();
        } catch (ConversationFailure failure) {
            try { send(emitter, event("RUN_ERROR", input, Map.of(
                    "code", failure.code(), "message", safeMessage(failure)))); }
            catch (IOException ignored) { }
            emitter.complete();
        } catch (Exception failure) {
            log.warn("Assistant run failed ({}): {}",
                    failure.getClass().getSimpleName(), failure.getMessage());
            try { send(emitter, event("RUN_ERROR", input, Map.of(
                    "code", "ASSISTANT_UNAVAILABLE", "message", "The assistant is unavailable."))); }
            catch (IOException ignored) { }
            emitter.complete();
        }
    }

    private void message(SseEmitter emitter, ConversationCoordinator.RunInput input,
                         ConversationCoordinator.Message message) throws IOException {
        send(emitter, event("TEXT_MESSAGE_START", input,
                Map.of("messageId", message.id().toString(), "role", "assistant")));
        send(emitter, event("TEXT_MESSAGE_CONTENT", input,
                Map.of("messageId", message.id().toString(), "delta", message.text())));
        send(emitter, event("TEXT_MESSAGE_END", input,
                Map.of("messageId", message.id().toString())));
    }

    private void tool(SseEmitter emitter, ConversationCoordinator.RunInput input,
                      ConversationCoordinator.Effect effect) throws IOException {
        String id = UUID.randomUUID().toString();
        send(emitter, event("TOOL_CALL_START", input, Map.of("toolCallId", id, "toolCallName", effect.name())));
        send(emitter, event("TOOL_CALL_ARGS", input, Map.of("toolCallId", id, "delta", effect.argumentsJson())));
        send(emitter, event("TOOL_CALL_END", input, Map.of("toolCallId", id)));
    }

    private Map<String, Object> interrupt(Proposal p) {
        Map<String, Object> metadata = new LinkedHashMap<>();
        metadata.put("proposalType", p.kind().name()); metadata.put("proposalVersion", p.schemaVersion());
        if (p.payload() instanceof Proposal.LogSessionPayload session) {
            metadata.put("sessionId", session.sessionId().toString());
            metadata.put("sankalpaId", session.sankalpaId().toString());
            metadata.put("sankalpaTitle", session.sankalpaTitle());
            metadata.put("occurredAt", session.occurredAt().toString());
            metadata.put("userSummary", session.userSummary());
        } else {
            Proposal.DeclareSankalpaPayload d = (Proposal.DeclareSankalpaPayload) p.payload();
            metadata.put("title", d.title()); metadata.put("description", d.description());
            metadata.put("actionType", d.actionType().name()); metadata.put("startDate", d.startDate().toString());
            metadata.put("periodUnit", d.periodUnit().name()); metadata.put("timesPerPeriod", d.timesPerPeriod());
            metadata.put("periodCount", d.periodCount()); metadata.put("inferredFields", d.inferredFields());
        }
        Map<String, Object> schema = Map.of("type", "object", "properties", Map.of(
                "decision", Map.of("type", "string", "enum", List.of("confirm")),
                "confirmationId", Map.of("type", "string", "format", "uuid")),
                "required", List.of("decision", "confirmationId"), "additionalProperties", false);
        Map<String, Object> item = new LinkedHashMap<>();
        item.put("id", p.id().toString()); item.put("reason", "confirmation");
        item.put("message", "Confirm this proposal before it is saved.");
        item.put("expiresAt", p.expiresAt().atZone(zone).toOffsetDateTime().toString());
        item.put("responseSchema", schema); item.put("metadata", metadata);
        return Map.of("type", "interrupt", "interrupts", List.of(item));
    }

    private ConversationCoordinator.RunInput validate(RunAgentInput input) {
        if (input == null) protocol("Request is required");
        UUID thread = uuid(input.threadId()); UUID run = uuid(input.runId());
        if (input.parentRunId() != null) uuid(input.parentRunId());
        if (input.state() == null || !input.state().isEmpty()
                || input.context() == null || !input.context().isEmpty()
                || input.forwardedProps() == null || !input.forwardedProps().isEmpty()) {
            protocol("Unsupported client state or context");
        }
        List<Message> messages = input.messages() == null ? List.of() : input.messages();
        if (messages.size() > 20) protocol("Too many messages");
        Set<String> ids = new HashSet<>();
        List<ConversationModel.Message> history = new ArrayList<>();
        for (Message message : messages) {
            if (message == null || !ids.add(message.id()) ||
                    !("user".equals(message.role()) || "assistant".equals(message.role())) ||
                    message.content() == null || message.content().length() > 16_000) protocol("Invalid message");
            uuid(message.id());
            history.add(new ConversationModel.Message(message.role(), message.content()));
        }
        if (input.tools() == null || input.tools().size() > 3) protocol("Invalid frontend tools");
        List<String> clientTools = input.tools().stream().map(Tool::name)
                .filter(Objects::nonNull).distinct().toList();
        ConversationCoordinator.Resume resume = null;
        if (input.resume() != null && !input.resume().isEmpty()) {
            if (input.resume().size() != 1 || !messages.isEmpty()) protocol("Invalid resume");
            Resume value = input.resume().getFirst();
            boolean cancelled = "cancelled".equals(value.status());
            UUID confirmation = null;
            if (!cancelled) {
                if (!"resolved".equals(value.status()) || value.payload() == null
                        || !"confirm".equals(value.payload().path("decision").asText())
                        || value.payload().size() != 2) protocol("Invalid confirmation");
                confirmation = uuid(value.payload().path("confirmationId").asText());
            } else if (value.payload() != null && !value.payload().isNull()) protocol("Cancellation has no payload");
            resume = new ConversationCoordinator.Resume(uuid(value.interruptId()), cancelled, confirmation);
        }
        if (resume == null && (history.isEmpty() || !"user".equals(history.getLast().role()))) {
            protocol("Latest message must be from the user");
        }
        return new ConversationCoordinator.RunInput(thread, run, history, clientTools, resume);
    }

    private static Map<String, Object> event(String type, ConversationCoordinator.RunInput input,
                                              Map<String, Object> fields) {
        Map<String, Object> value = new LinkedHashMap<>(); value.put("type", type);
        value.put("threadId", input.threadId().toString()); value.put("runId", input.runId().toString());
        value.putAll(fields); return value;
    }
    private static void send(SseEmitter emitter, Object event) throws IOException {
        emitter.send(SseEmitter.event().data(event, MediaType.APPLICATION_JSON));
    }
    private static UUID uuid(String value) { try { return UUID.fromString(value); } catch (Exception e) { protocol("Invalid UUID"); return null; } }
    private static void protocol(String detail) { throw new ConversationFailure("AGUI_PROTOCOL_ERROR", detail); }
    private static String safeMessage(ConversationFailure failure) {
        return failure.code().startsWith("ASSISTANT_") || failure.code().startsWith("PROPOSAL_")
                ? failure.getMessage() : "The assistant could not complete that request.";
    }
}
