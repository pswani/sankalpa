package com.sankalpa.adapter;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.sankalpa.adapter.out.llm.LangChain4jConversationModel;
import com.sankalpa.application.conversation.ConversationModel;
import dev.langchain4j.agent.tool.ToolExecutionRequest;
import dev.langchain4j.data.message.AiMessage;
import dev.langchain4j.model.chat.ChatModel;
import dev.langchain4j.model.chat.request.ChatRequest;
import dev.langchain4j.model.chat.response.ChatResponse;
import org.junit.jupiter.api.Test;

import java.util.List;
import java.util.concurrent.atomic.AtomicReference;

import static org.assertj.core.api.Assertions.assertThat;

class LangChain4jConversationModelTest {
    @Test
    void replayedToolCallsKeepTheArgumentsTheModelSent() {
        AtomicReference<ChatRequest> sent = new AtomicReference<>();
        ChatModel chat = new ChatModel() {
            @Override public ChatResponse doChat(ChatRequest request) {
                sent.set(request);
                return ChatResponse.builder().aiMessage(AiMessage.from("Done")).build();
            }
        };
        String arguments = "{\"sankalpaId\":\"8d9f3c1e-1111-4a2b-9c3d-222222222222\"}";

        new LangChain4jConversationModel(chat, new ObjectMapper()).respond(request(List.of(
                new ConversationModel.ToolResult("read", "get_sankalpa", arguments, "{}"),
                new ConversationModel.ToolResult("bad", "propose_log_session", "{not-json",
                        "{\"error\":\"INVALID_TOOL_REQUEST\"}"))));

        List<String> replayed = sent.get().messages().stream()
                .filter(AiMessage.class::isInstance).map(AiMessage.class::cast)
                .flatMap(message -> message.toolExecutionRequests().stream())
                .map(ToolExecutionRequest::arguments).toList();
        assertThat(replayed).containsExactly(arguments, "{}");
    }

    private static ConversationModel.ModelRequest request(List<ConversationModel.ToolResult> results) {
        return new ConversationModel.ModelRequest(
                List.of(new ConversationModel.Message("user", "How is my practice?")),
                new ConversationModel.Context("2026-09-26T08:00", "UTC", List.of()),
                List.of(), results, 1);
    }
}
