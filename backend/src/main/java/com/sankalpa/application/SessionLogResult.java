package com.sankalpa.application;

import com.sankalpa.domain.Session;

import java.util.Objects;

public record SessionLogResult(Session session, boolean created) {
    public SessionLogResult {
        Objects.requireNonNull(session, "session is required");
    }
}
