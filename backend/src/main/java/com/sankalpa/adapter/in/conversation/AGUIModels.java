package com.sankalpa.adapter.in.conversation;

import com.fasterxml.jackson.databind.JsonNode;

import java.util.List;
import java.util.Map;

public final class AGUIModels {
    private AGUIModels() {}

    public record RunAgentInput(String threadId, String runId, String parentRunId,
                                Map<String, Object> state, List<Message> messages,
                                List<Tool> tools, List<Object> context,
                                Map<String, Object> forwardedProps, List<Resume> resume) {}
    public record Message(String id, String role, String content) {}
    public record Tool(String name, String description, JsonNode parameters) {}
    public record Resume(String interruptId, String status, JsonNode payload) {}
}
