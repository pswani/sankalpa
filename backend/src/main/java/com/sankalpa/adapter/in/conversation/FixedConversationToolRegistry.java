package com.sankalpa.adapter.in.conversation;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ObjectNode;
import com.sankalpa.application.SankalpaUseCases;
import com.sankalpa.application.conversation.*;
import com.sankalpa.domain.ActionType;
import com.sankalpa.domain.DomainException;
import com.sankalpa.domain.SankalpaId;
import com.sankalpa.domain.commitment.PeriodUnit;

import java.time.LocalDate;
import java.time.LocalDateTime;
import java.time.OffsetDateTime;
import java.time.format.DateTimeParseException;
import java.util.*;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

/** Fixed allowlist. Client input can remove frontend effects, never add server capabilities. */
public final class FixedConversationToolRegistry implements ConversationToolExecutor {
    private static final Logger log = LoggerFactory.getLogger(FixedConversationToolRegistry.class);
    private static final Set<String> SERVER_TOOLS = Set.of(
            "get_sankalpa", "get_recent_sessions", "get_period_summary",
            "propose_log_session", "propose_declare_sankalpa");
    private static final Set<String> FRONTEND_TOOLS = Set.of(
            "navigate_to_sankalpa", "open_sankalpa_list");
    private final ObjectMapper json;
    private final SankalpaUseCases sankalpas;
    private final ConversationUseCases proposals;

    public FixedConversationToolRegistry(ObjectMapper json, SankalpaUseCases sankalpas,
                                         ConversationUseCases proposals) {
        this.json = json;
        this.sankalpas = sankalpas;
        this.proposals = proposals;
    }

    @Override
    public List<ConversationModel.ToolDefinition> definitions(List<String> clientTools) {
        List<ConversationModel.ToolDefinition> definitions = new ArrayList<>(List.of(
                definition("get_sankalpa", "Read one bounded Sankalpa detail.", objectSchema("sankalpaId")),
                definition("get_recent_sessions", "Read up to 50 sessions in a date range.", rangeSchema()),
                definition("get_period_summary", "Read up to 50 period outcomes in a date range.", rangeSchema()),
                definition("propose_log_session", "Create a non-mutating session proposal.", """
                    {"type":"object","properties":{"sankalpaId":{"type":"string","format":"uuid"},"occurredAt":{"type":"string","description":"ISO 8601 local or offset date-time"},"userSummary":{"type":"string","maxLength":200},"alternativeSankalpaIds":{"type":"array","items":{"type":"string","format":"uuid"},"maxItems":3}},"required":["sankalpaId","occurredAt","userSummary","alternativeSankalpaIds"],"additionalProperties":false}
                    """),
                definition("propose_declare_sankalpa", "Create a non-mutating declaration proposal.", """
                    {"type":"object","properties":{"title":{"type":"string","maxLength":200},"description":{"type":"string","maxLength":2000},"actionType":{"type":"string","enum":["MEDITATION","PRANAYAMA","PHYSICAL_ACTIVITY","OBSERVANCE"]},"startDate":{"type":"string"},"periodUnit":{"type":"string","enum":["DAY","WEEK","MONTH","YEAR"]},"timesPerPeriod":{"type":"integer"},"periodCount":{"type":["integer","null"]},"inferredFields":{"type":"array","items":{"type":"string"}}},"required":["title","description","actionType","startDate","periodUnit","timesPerPeriod","periodCount","inferredFields"],"additionalProperties":false}
                    """)));
        if (clientTools.contains("navigate_to_sankalpa")) {
            definitions.add(definition("navigate_to_sankalpa", "Open one known Sankalpa in the app.",
                    objectSchema("sankalpaId")));
        }
        if (clientTools.contains("open_sankalpa_list")) {
            definitions.add(definition("open_sankalpa_list", "Open the Sankalpa list in the app.",
                    "{\"type\":\"object\",\"properties\":{},\"required\":[],\"additionalProperties\":false}"));
        }
        return List.copyOf(definitions);
    }

    @Override
    public Outcome execute(ConversationModel.ToolCall call, UUID threadId, UUID runId,
                           ConversationModel.Context context, List<String> clientTools) {
        try {
            return executeValidated(call, threadId, runId, context, clientTools);
        } catch (ConversationFailure failure) {
            throw failure;
        } catch (DomainException | IllegalArgumentException failure) {
            log.warn("Assistant tool contract rejected ({}): {}", call == null ? "unknown" : call.name(),
                    failure.getMessage());
            invalid("Tool arguments violate the Sankalpa contract");
            return null;
        }
    }

    private Outcome executeValidated(ConversationModel.ToolCall call, UUID threadId, UUID runId,
                                     ConversationModel.Context context, List<String> clientTools) {
        if (call == null || call.name() == null || call.id() == null) invalid("Malformed tool request");
        JsonNode args = parseObject(call.argumentsJson());
        if (FRONTEND_TOOLS.contains(call.name())) {
            if (!clientTools.contains(call.name())) invalid("Frontend tool is not advertised");
            if (call.name().equals("open_sankalpa_list")) {
                exact(args, Set.of());
            } else {
                exact(args, Set.of("sankalpaId"));
                UUID id = uuid(requiredText(args, "sankalpaId"));
                if (context.sankalpas().stream().noneMatch(s -> s.id().equals(id.toString()))) {
                    invalid("Unknown Sankalpa id");
                }
            }
            return new FrontendEffect(call.name(), compact(args));
        }
        if (!SERVER_TOOLS.contains(call.name())) invalid("Unknown tool");
        return switch (call.name()) {
            case "get_sankalpa" -> readSankalpa(args);
            case "get_recent_sessions" -> recentSessions(args);
            case "get_period_summary" -> periodSummary(args);
            case "propose_log_session" -> proposeSession(args, threadId, runId, context);
            case "propose_declare_sankalpa" -> proposeDeclaration(args, threadId, runId);
            default -> throw new AssertionError(call.name());
        };
    }

    private Outcome readSankalpa(JsonNode args) {
        exact(args, Set.of("sankalpaId"));
        var s = sankalpas.detail(SankalpaId.parse(requiredText(args, "sankalpaId")));
        String description = s.description().value();
        boolean truncated = description.length() > 2_000;
        if (truncated) description = description.substring(0, 2_000);
        Map<String, Object> result = new LinkedHashMap<>();
        result.put("id", s.id().toString()); result.put("title", s.title().value());
        result.put("description", description); result.put("descriptionTruncated", truncated);
        result.put("actionType", s.actionType().name());
        result.put("lifecycleState", s.lifecycle().current().name());
        result.put("startDate", s.commitment().startDate().toString());
        result.put("endDate", s.commitment().endDate().map(Object::toString).orElse(null));
        result.put("periodUnit", s.commitment().periodUnit().name());
        result.put("timesPerPeriod", s.commitment().timesPerPeriod());
        return new ReadResult(write(result));
    }

    private Outcome recentSessions(JsonNode args) {
        Range range = range(args);
        var page = sankalpas.sessions(range.id, range.from, range.until, 0, range.limit);
        var items = page.content().stream().map(s -> Map.of(
                "sessionId", s.id().toString(), "occurredAt", s.occurredAt().toString())).toList();
        return new ReadResult(write(Map.of("items", items, "truncated", page.totalElements() > items.size())));
    }

    private Outcome periodSummary(JsonNode args) {
        Range range = range(args);
        var all = sankalpas.periodOutcomes(range.id, range.from, range.until);
        boolean truncated = all.size() > range.limit;
        var items = all.stream().limit(range.limit).map(p -> Map.of(
                "start", p.window().start().toString(), "end", p.window().end().toString(),
                "required", p.required(), "performed", p.performed(), "missed", p.missed(),
                "standing", p.standing().name())).toList();
        return new ReadResult(write(Map.of("items", items, "truncated", truncated)));
    }

    private Outcome proposeSession(JsonNode args, UUID threadId, UUID runId,
                                   ConversationModel.Context context) {
        exact(args, Set.of("sankalpaId", "occurredAt", "userSummary", "alternativeSankalpaIds"));
        SankalpaId id = SankalpaId.parse(requiredText(args, "sankalpaId"));
        if (context.sankalpas().stream().noneMatch(s -> s.id().equals(id.toString()))) invalid("Unknown Sankalpa id");
        JsonNode alternatives = args.get("alternativeSankalpaIds");
        if (alternatives == null || !alternatives.isArray() || alternatives.size() > 3) invalid("Invalid alternatives");
        List<SankalpaId> alternativeIds = new ArrayList<>();
        alternatives.forEach(value -> alternativeIds.add(SankalpaId.parse(value.asText())));
        return new ProposalResult(proposals.proposeSession(threadId, runId, id,
                localDateTime(requiredText(args, "occurredAt")),
                requiredText(args, "userSummary"), alternativeIds));
    }

    private Outcome proposeDeclaration(JsonNode args, UUID threadId, UUID runId) {
        exact(args, Set.of("title", "description", "actionType", "startDate", "periodUnit",
                "timesPerPeriod", "periodCount", "inferredFields"));
        JsonNode inferred = args.get("inferredFields");
        if (inferred == null || !inferred.isArray()) invalid("Invalid inferred fields");
        List<String> fields = new ArrayList<>(); inferred.forEach(v -> fields.add(v.asText()));
        JsonNode count = args.get("periodCount");
        Integer periodCount = count == null || count.isNull() ? null : count.asInt();
        return new ProposalResult(proposals.proposeDeclaration(threadId, runId,
                requiredText(args, "title"), requiredText(args, "description"),
                ActionType.valueOf(requiredText(args, "actionType")),
                LocalDate.parse(requiredText(args, "startDate")),
                PeriodUnit.valueOf(requiredText(args, "periodUnit")),
                requiredInt(args, "timesPerPeriod"), periodCount, fields));
    }

    private Range range(JsonNode args) {
        exact(args, Set.of("sankalpaId", "from", "until", "limit"));
        int limit = requiredInt(args, "limit");
        if (limit < 1 || limit > 50) invalid("Invalid read limit");
        LocalDate from = LocalDate.parse(requiredText(args, "from"));
        LocalDate until = LocalDate.parse(requiredText(args, "until"));
        if (from.isAfter(until)) invalid("Invalid date range");
        return new Range(SankalpaId.parse(requiredText(args, "sankalpaId")), from, until, limit);
    }

    private JsonNode parseObject(String value) {
        try {
            JsonNode node = json.readTree(value);
            if (!(node instanceof ObjectNode)) invalid("Tool arguments must be an object");
            return node;
        } catch (JsonProcessingException e) { invalid("Malformed tool arguments"); return null; }
    }
    private void exact(JsonNode args, Set<String> expected) {
        Set<String> actual = new HashSet<>(); args.fieldNames().forEachRemaining(actual::add);
        if (!actual.equals(expected)) invalid("Tool arguments do not match the schema");
    }
    private String requiredText(JsonNode args, String name) {
        JsonNode value = args.get(name);
        if (value == null || !value.isTextual()) invalid("Invalid " + name);
        return value.textValue();
    }
    private int requiredInt(JsonNode args, String name) {
        JsonNode value = args.get(name);
        if (value == null || !value.isIntegralNumber()) invalid("Invalid " + name);
        return value.intValue();
    }
    private String write(Object value) {
        try { return json.writeValueAsString(value); }
        catch (JsonProcessingException e) { throw new IllegalStateException(e); }
    }
    private String compact(JsonNode value) { return write(value); }
    private static LocalDateTime localDateTime(String value) {
        try {
            return LocalDateTime.parse(value);
        } catch (DateTimeParseException localFailure) {
            try {
                // The domain stores the user's wall-clock time. An offset supplied by the model
                // describes that same wall-clock value; retaining it avoids shifting "7 PM".
                return OffsetDateTime.parse(value).toLocalDateTime();
            } catch (DateTimeParseException offsetFailure) {
                invalid("Invalid occurredAt");
                return null;
            }
        }
    }
    private static UUID uuid(String value) { try { return UUID.fromString(value); } catch (IllegalArgumentException e) { invalid("Invalid UUID"); return null; } }
    private static void invalid(String detail) { throw new ConversationFailure("ASSISTANT_COULD_NOT_INTERPRET", detail); }
    private static ConversationModel.ToolDefinition definition(String name, String description, String schema) {
        return new ConversationModel.ToolDefinition(name, description, schema);
    }
    private static String objectSchema(String field) { return "{\"type\":\"object\",\"properties\":{\"" + field + "\":{\"type\":\"string\",\"format\":\"uuid\"}},\"required\":[\"" + field + "\"],\"additionalProperties\":false}"; }
    private static String rangeSchema() { return "{\"type\":\"object\",\"properties\":{\"sankalpaId\":{\"type\":\"string\"},\"from\":{\"type\":\"string\"},\"until\":{\"type\":\"string\"},\"limit\":{\"type\":\"integer\",\"minimum\":1,\"maximum\":50}},\"required\":[\"sankalpaId\",\"from\",\"until\",\"limit\"],\"additionalProperties\":false}"; }
    private record Range(SankalpaId id, LocalDate from, LocalDate until, int limit) {}
}
