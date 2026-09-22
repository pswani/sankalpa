package com.sankalpa.domain;

import java.time.LocalDateTime;

public record Session(SessionId id, SankalpaId sankalpaId, LocalDateTime occurredAt, LocalDateTime loggedAt) {
    public Session {
        if (id == null || sankalpaId == null || occurredAt == null || loggedAt == null) {
            throw new IllegalArgumentException("Session fields are required");
        }
    }
}
