package com.sankalpa.adapter.config;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.sankalpa.adapter.in.conversation.FixedConversationToolRegistry;
import com.sankalpa.adapter.out.llm.LangChain4jConversationModel;
import com.sankalpa.adapter.out.llm.ScriptedConversationModel;
import com.sankalpa.application.SankalpaUseCases;
import com.sankalpa.application.conversation.*;
import com.sankalpa.application.port.SankalpaClock;
import dev.langchain4j.model.openai.OpenAiChatModel;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

import java.time.Duration;
import java.time.ZoneId;

@Configuration
public class ConversationConfiguration {
    @Bean
    @ConditionalOnProperty(name = "sankalpa.assistant.provider", havingValue = "openai")
    @ConditionalOnProperty(name = "sankalpa.assistant.enabled", havingValue = "true")
    ConversationModel langChain4jConversationModel(ObjectMapper json,
            @Value("${sankalpa.assistant.model}") String model,
            @Value("${sankalpa.assistant.api-key}") String apiKey,
            @Value("${sankalpa.assistant.timeout:PT30S}") Duration timeout,
            @Value("${sankalpa.assistant.reasoning-effort:none}") String reasoningEffort) {
        var chat = OpenAiChatModel.builder().modelName(model).apiKey(apiKey).timeout(timeout)
                .reasoningEffort(reasoningEffort)
                .maxRetries(0).parallelToolCalls(false).strictTools(true)
                .logRequests(false).logResponses(false).build();
        return new LangChain4jConversationModel(chat, json);
    }

    @Bean
    @org.springframework.context.annotation.Conditional(ScriptedWhenDisabledOrFake.class)
    ScriptedConversationModel scriptedConversationModel() { return new ScriptedConversationModel(); }

    @Bean
    ConversationContextLoader conversationContextLoader(SankalpaUseCases sankalpas,
            SankalpaClock clock, @Value("${sankalpa.timezone}") String timezone) {
        return new ConversationContextLoader(sankalpas, clock, ZoneId.of(timezone));
    }

    @Bean
    ConversationToolExecutor conversationToolExecutor(ObjectMapper json,
            SankalpaUseCases sankalpas, ConversationUseCases proposals) {
        return new FixedConversationToolRegistry(json, sankalpas, proposals);
    }

    @Bean
    ConversationCoordinator conversationCoordinator(ConversationModel model,
            ConversationContextLoader context, ConversationToolExecutor tools,
            ConversationUseCases proposals, org.springframework.beans.factory.ObjectProvider<ConversationRunGuard> guard) {
        return new ConversationCoordinator(model, context, tools, proposals, guard.getIfAvailable());
    }
    static final class ScriptedWhenDisabledOrFake implements org.springframework.context.annotation.Condition {
        public boolean matches(org.springframework.context.annotation.ConditionContext context, org.springframework.core.type.AnnotatedTypeMetadata metadata) {
            var environment = context.getEnvironment();
            return !environment.getProperty("sankalpa.assistant.enabled", Boolean.class, false)
                || "fake".equals(environment.getProperty("sankalpa.assistant.provider", "fake"));
        }
    }

}
