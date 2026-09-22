package com.sankalpa.domain.lifecycle;

import java.time.LocalDateTime;

public record LifecycleTransition(
        LifecycleState from,
        LifecycleState to,
        LocalDateTime effectiveAt,
        LocalDateTime recordedAt
) {
    public LifecycleTransition {
        if (from == null || to == null || effectiveAt == null || recordedAt == null) {
            throw new IllegalArgumentException("Lifecycle transition fields are required");
        }
    }
}
