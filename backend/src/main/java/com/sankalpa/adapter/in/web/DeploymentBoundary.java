package com.sankalpa.adapter.in.web;

import jakarta.annotation.PostConstruct;
import jakarta.servlet.*;
import jakarta.servlet.http.*;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Component;
import org.springframework.core.annotation.Order;
import org.springframework.web.filter.OncePerRequestFilter;
import java.io.IOException;

@Component @Order(0)
public final class DeploymentBoundary extends OncePerRequestFilter {
    private final boolean cloud;
    private final String token;
    public DeploymentBoundary(@Value("${sankalpa.deployment:local}") String deployment,
            @Value("${sankalpa.assistant.api-token:}") String token) {
        cloud = !"local".equals(deployment); this.token = token;
    }
    @PostConstruct void validate() {
        if (cloud && token.isBlank()) throw new IllegalStateException("Cloud deployment requires SANKALPA_API_TOKEN");
    }
    protected void doFilterInternal(HttpServletRequest request, HttpServletResponse response, FilterChain chain) throws ServletException, IOException {
        String path = request.getRequestURI();
        if (cloud && !path.startsWith("/api/v1/") && !path.equals("/health/ready")) { response.sendError(404); return; }
        chain.doFilter(request, response);
    }
}
