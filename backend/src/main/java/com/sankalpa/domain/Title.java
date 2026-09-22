package com.sankalpa.domain;

public record Title(String value) {
    public Title {
        if (value == null || value.isBlank()) {
            throw new DomainException("INVALID_TITLE", "Title must not be blank");
        }
        value = value.trim();
        if (value.length() > 200) {
            throw new DomainException("INVALID_TITLE", "Title must not exceed 200 characters");
        }
    }
}
