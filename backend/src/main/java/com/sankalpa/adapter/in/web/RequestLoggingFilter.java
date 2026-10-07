package com.sankalpa.adapter.in.web;

import jakarta.servlet.FilterChain;
import jakarta.servlet.ServletException;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.core.annotation.Order;
import org.springframework.stereotype.Component;
import org.springframework.web.filter.OncePerRequestFilter;

import java.io.IOException;

/**
 * One line per API request: method, path, status, the problem code of a refusal, and duration.
 * Changes and failures log at INFO; successful reads at DEBUG, because every app refresh issues
 * several. Bodies and query strings are never logged: they carry the user's own practice text.
 */
@Component
@Order(0)
public final class RequestLoggingFilter extends OncePerRequestFilter {
    static final String PROBLEM_CODE = RequestLoggingFilter.class.getName() + ".problemCode";
    private static final Logger log = LoggerFactory.getLogger(RequestLoggingFilter.class);

    @Override protected boolean shouldNotFilter(HttpServletRequest request) {
        return !request.getRequestURI().startsWith("/api/");
    }

    @Override
    protected void doFilterInternal(HttpServletRequest request, HttpServletResponse response,
                                    FilterChain chain) throws ServletException, IOException {
        long started = System.nanoTime();
        try {
            chain.doFilter(request, response);
        } finally {
            int status = response.getStatus();
            Object code = request.getAttribute(PROBLEM_CODE);
            long millis = (System.nanoTime() - started) / 1_000_000;
            boolean routine = "GET".equals(request.getMethod()) && status < 400;
            String line = "{} {} -> {}{} ({} ms)";
            Object[] values = {request.getMethod(), request.getRequestURI(), status,
                    code == null ? "" : " " + code, millis};
            if (routine) log.debug(line, values); else log.info(line, values);
        }
    }
}
