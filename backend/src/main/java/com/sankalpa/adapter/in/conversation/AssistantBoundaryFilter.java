package com.sankalpa.adapter.in.conversation;

import jakarta.servlet.FilterChain;
import jakarta.servlet.ServletException;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.core.annotation.Order;
import org.springframework.stereotype.Component;
import org.springframework.web.filter.OncePerRequestFilter;

import java.io.IOException;
import java.time.Clock;
import java.util.ArrayDeque;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;

/** Bounded single-node protection for the single-user assistant endpoint. */
@Component
@Order(20)
public final class AssistantBoundaryFilter extends OncePerRequestFilter {
    static final long MAX_BODY_BYTES = 256 * 1024;
    private final int runsPerMinute;
    private final Clock clock;
    private final Map<String, ArrayDeque<Long>> requests = new ConcurrentHashMap<>();

    @Autowired
    public AssistantBoundaryFilter(
            @Value("${sankalpa.assistant.runs-per-minute:30}") int runsPerMinute) {
        this(runsPerMinute, Clock.systemUTC());
    }

    AssistantBoundaryFilter(int runsPerMinute, Clock clock) {
        this.runsPerMinute = runsPerMinute;
        this.clock = clock;
    }

    @Override protected boolean shouldNotFilter(HttpServletRequest request) {
        return !"/api/v1/assistant/runs".equals(request.getRequestURI());
    }

    @Override
    protected void doFilterInternal(HttpServletRequest request, HttpServletResponse response,
                                    FilterChain chain) throws ServletException, IOException {
        long length = request.getContentLengthLong();
        if (length > MAX_BODY_BYTES) {
            reject(response, HttpServletResponse.SC_REQUEST_ENTITY_TOO_LARGE,
                    "ASSISTANT_LIMIT_REACHED", "Assistant request is too large.");
            return;
        }
        String key = request.getRemoteAddr();
        long now = clock.millis();
        ArrayDeque<Long> bucket = requests.computeIfAbsent(key, ignored -> new ArrayDeque<>());
        synchronized (bucket) {
            while (!bucket.isEmpty() && bucket.peekFirst() <= now - 60_000) bucket.removeFirst();
            if (bucket.size() >= runsPerMinute) {
                reject(response, 429, "ASSISTANT_RATE_LIMITED", "Too many assistant requests. Try again shortly.");
                return;
            }
            bucket.addLast(now);
        }
        chain.doFilter(request, response);
    }

    private static void reject(HttpServletResponse response, int status, String code, String detail)
            throws IOException {
        response.setStatus(status);
        response.setCharacterEncoding("UTF-8");
        response.setContentType("application/problem+json");
        response.getWriter().write("{\"code\":\"" + code + "\",\"detail\":\"" + detail + "\"}");
    }
}
