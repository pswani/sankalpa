package com.sankalpa.domain;

public record Description(String value) {
    public Description {
        value = value == null ? "" : value.trim();
    }
}
