package com.sankalpa.adapter.in.web;

import jakarta.servlet.FilterChain;
import jakarta.servlet.ServletException;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Component;
import org.springframework.core.annotation.Order;
import org.springframework.web.filter.OncePerRequestFilter;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;

/** Optional single-user bearer boundary. Configure SANKALPA_API_TOKEN for remote use. */
@Component
@Order(10)
public final class BearerAuthenticationFilter extends OncePerRequestFilter {
    private final byte[] expected;

    public BearerAuthenticationFilter(@Value("${sankalpa.assistant.api-token:}") String token) {
        this.expected = token.getBytes(StandardCharsets.UTF_8);
    }

    @Override protected boolean shouldNotFilter(HttpServletRequest request) {
        return expected.length == 0 || !request.getRequestURI().startsWith("/api/v1/");
    }

    @Override
    protected void doFilterInternal(HttpServletRequest request, HttpServletResponse response,
                                    FilterChain chain) throws ServletException, IOException {
        String header = request.getHeader("Authorization");
        byte[] actual = header != null && header.startsWith("Bearer ")
                ? header.substring(7).getBytes(StandardCharsets.UTF_8) : new byte[0];
        if (!MessageDigest.isEqual(expected, actual)) {
            response.setStatus(HttpServletResponse.SC_UNAUTHORIZED);
            response.setCharacterEncoding("UTF-8");
            response.setContentType("application/problem+json");
            response.getWriter().write("{\"code\":\"UNAUTHORIZED\",\"detail\":\"A valid bearer token is required.\"}");
            return;
        }
        chain.doFilter(request, response);
    }
}
