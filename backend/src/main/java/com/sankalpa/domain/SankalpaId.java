package com.sankalpa.domain;

import java.util.UUID;

public record SankalpaId(UUID value) {
    public SankalpaId {
        if (value == null) throw new IllegalArgumentException("Sankalpa id is required");
    }

    public static SankalpaId newId() { return new SankalpaId(UUID.randomUUID()); }
    public static SankalpaId parse(String value) { return new SankalpaId(UUID.fromString(value)); }
    @Override public String toString() { return value.toString(); }
}
