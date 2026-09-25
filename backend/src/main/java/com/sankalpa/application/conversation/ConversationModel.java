package com.sankalpa.application.conversation;

import java.util.List;

/** Provider-neutral application port. Provider classes must remain in outbound adapters. */
public interface ConversationModel {
    ModelTurn respond(ModelRequest request);

    record Message(String role, String content) {}
    record Context(String now, String timezone, List<SankalpaSummary> sankalpas) {}
    record SankalpaSummary(String id, String title, String description,
                           boolean descriptionTruncated, String actionType,
                           String lifecycleState, String startDate, String endDate,
                           String periodUnit, int timesPerPeriod) {}
    record ToolDefinition(String name, String description, String inputSchema) {}
    record ModelRequest(List<Message> messages, Context context,
                        List<ToolDefinition> tools, List<ToolResult> results,
                        int remainingToolCalls) {}
    record ToolCall(String id, String name, String argumentsJson) {}
    record ToolResult(String id, String name, String resultJson) {}

    sealed interface ModelTurn permits TextTurn, ToolRequestsTurn, RefusalTurn {}
    record TextTurn(String text) implements ModelTurn {}
    record ToolRequestsTurn(List<ToolCall> requests) implements ModelTurn {}
    record RefusalTurn(String reason) implements ModelTurn {}
}
