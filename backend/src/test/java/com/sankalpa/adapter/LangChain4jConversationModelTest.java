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

    @Test void batchUnionSchemaSurvivesTheLangChainAdapterAndBudgetIsExplained() {
        var registry=new com.sankalpa.adapter.in.conversation.FixedConversationToolRegistry(new ObjectMapper(),null,null);
        var definition=registry.definitions(List.of("batch_sessions_v1")).stream().filter(t->t.name().equals("propose_log_sessions")).findFirst().orElseThrow();
        AtomicReference<ChatRequest> sent=new AtomicReference<>();
        ChatModel chat=new ChatModel(){@Override public ChatResponse doChat(ChatRequest request){sent.set(request);return ChatResponse.builder().aiMessage(AiMessage.from("Choose a time")).build();}};
        var request=new ConversationModel.ModelRequest(List.of(new ConversationModel.Message("user","Record daily")),
                new ConversationModel.Context("2026-10-17T18:00","America/Chicago",List.of()),List.of(definition),List.of(),2);
        new LangChain4jConversationModel(chat,new ObjectMapper()).respond(request);
        assertThat(sent.get().toolSpecifications()).hasSize(1);
        assertThat(sent.get().toolSpecifications().getFirst().name()).isEqualTo("propose_log_sessions");
        assertThat(sent.get().messages().getFirst().toString()).contains("Remaining tool calls: 2", "day-based report");
    }

    @Test void modelReceivesActionableDomainFailureInsteadOfJustAnErrorCode() throws Exception {
        AtomicReference<ChatRequest> sent = new AtomicReference<>();
        ChatModel chat = new ChatModel() {
            @Override public ChatResponse doChat(ChatRequest request) {
                sent.set(request); return ChatResponse.builder().aiMessage(AiMessage.from("Review the earlier Begin")).build();
            }
        };
        var failure = new ConversationModel.ToolError("INVALID_DATE", "Earlier than recorded Begin; changing the time cannot fix it.",
                java.util.Map.of("beganAt", "2026-10-17T18:08:54", "domainCode", "SANKALPA_NOT_IN_PROGRESS"));
        new LangChain4jConversationModel(chat, new ObjectMapper()).respond(request(List.of(
                new ConversationModel.ToolResult("repair", "propose_log_sessions", "{}", "{}", failure))));
        var result = sent.get().messages().stream()
                .filter(dev.langchain4j.data.message.ToolExecutionResultMessage.class::isInstance)
                .map(dev.langchain4j.data.message.ToolExecutionResultMessage.class::cast).findFirst().orElseThrow();
        var json = new ObjectMapper().readTree(result.text());
        assertThat(json.path("message").asText()).contains("changing the time cannot fix");
        assertThat(json.path("details").path("beganAt").asText()).isEqualTo("2026-10-17T18:08:54");
    }

    private static ConversationModel.ModelRequest request(List<ConversationModel.ToolResult> results) {
        return new ConversationModel.ModelRequest(
                List.of(new ConversationModel.Message("user", "How is my practice?")),
                new ConversationModel.Context("2026-09-26T08:00", "UTC", List.of()),
                List.of(), results, 1);
    }
}
