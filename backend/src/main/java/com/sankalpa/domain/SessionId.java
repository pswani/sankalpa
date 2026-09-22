package com.sankalpa.domain;

import java.util.UUID;

public record SessionId(UUID value) {
    public SessionId {
        if (value == null) throw new IllegalArgumentException("Session id is required");
    }

    public static SessionId newId() { return new SessionId(UUID.randomUUID()); }
    public static SessionId parse(String value) { return new SessionId(UUID.fromString(value)); }
    @Override public String toString() { return value.toString(); }
}
