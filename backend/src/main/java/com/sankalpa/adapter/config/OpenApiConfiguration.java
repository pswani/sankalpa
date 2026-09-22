package com.sankalpa.adapter.config;

import io.swagger.v3.oas.models.OpenAPI;
import io.swagger.v3.oas.models.info.Info;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

@Configuration
public class OpenApiConfiguration {
    @Bean
    OpenAPI sankalpaOpenApi() {
        return new OpenAPI().info(new Info()
                .title("Sankalpa REST API")
                .version("v1")
                .description("Single-user API for declaring commitments, lifecycle tracking, sessions, and period outcomes."));
    }
}
