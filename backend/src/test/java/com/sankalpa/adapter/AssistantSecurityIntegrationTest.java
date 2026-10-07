package com.sankalpa.adapter;

import com.sankalpa.adapter.out.llm.ScriptedConversationModel;
import com.sankalpa.application.conversation.ConversationModel;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.test.context.ActiveProfiles;
import org.springframework.test.web.servlet.MockMvc;

import java.util.UUID;

import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.*;

@SpringBootTest(properties = {
        "sankalpa.assistant.enabled=true",
        "sankalpa.assistant.provider=fake",
        "sankalpa.assistant.api-token=test-secret",
        "sankalpa.assistant.runs-per-minute=1"
})
@ActiveProfiles("test")
@AutoConfigureMockMvc
class AssistantSecurityIntegrationTest {
    @Autowired MockMvc mvc;
    @Autowired ScriptedConversationModel model;

    @Test
    void authenticationPrecedesModelAndAuthenticatedRunsAreRateLimited() throws Exception {
        String body = """
                {"threadId":"%s","runId":"%s","state":{},"messages":[
                  {"id":"%s","role":"user","content":"Hello"}],"tools":[],
                  "context":[],"forwardedProps":{}}
                """.formatted(UUID.randomUUID(), UUID.randomUUID(), UUID.randomUUID());

        mvc.perform(post("/api/v1/assistant/runs").contentType("application/json").content(body))
                .andExpect(status().isUnauthorized())
                .andExpect(jsonPath("$.code").value("UNAUTHORIZED"));
        mvc.perform(get("/api/v1/capabilities"))
                .andExpect(status().isUnauthorized());

        model.enqueue(new ConversationModel.TextTurn("Hello."));
        mvc.perform(post("/api/v1/assistant/runs").header("Authorization", "Bearer test-secret")
                        .contentType("application/json").accept("text/event-stream").content(body))
                .andExpect(request().asyncStarted());

        mvc.perform(post("/api/v1/assistant/runs").header("Authorization", "Bearer test-secret")
                        .contentType("application/json").content(body))
                .andExpect(status().isTooManyRequests())
                .andExpect(jsonPath("$.code").value("ASSISTANT_RATE_LIMITED"));
    }
}
