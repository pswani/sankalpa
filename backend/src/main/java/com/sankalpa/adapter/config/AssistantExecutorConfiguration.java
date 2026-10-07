package com.sankalpa.adapter.config;

import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.scheduling.concurrent.ThreadPoolTaskExecutor;

@Configuration
public class AssistantExecutorConfiguration {
    @Bean("assistantExecutor")
    ThreadPoolTaskExecutor assistantExecutor() {
        ThreadPoolTaskExecutor executor = new ThreadPoolTaskExecutor();
        executor.setCorePoolSize(2); executor.setMaxPoolSize(4); executor.setQueueCapacity(16);
        executor.setThreadNamePrefix("assistant-"); executor.initialize();
        return executor;
    }
}
