package com.sankalpa.application;

import com.sankalpa.domain.SankalpaId;
import com.sankalpa.domain.SessionId;

import java.util.Objects;

public record SessionIdentity(
        SessionId sessionId,
        SankalpaId sankalpaId,
        SessionIdentityState state
) {
    public SessionIdentity {
        Objects.requireNonNull(sessionId, "sessionId is required");
        Objects.requireNonNull(sankalpaId, "sankalpaId is required");
        Objects.requireNonNull(state, "state is required");
    }
}
