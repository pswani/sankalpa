package com.sankalpa.application;

import java.util.Map;

/** Application/contract refusal, deliberately outside the conversation domain-refusal catch. */
public final class PracticeException extends RuntimeException {
    private final String code;
    private final Map<String, String> errors;
    public PracticeException(String code, String message) { this(code, message, Map.of()); }
    public PracticeException(String code, String message, Map<String, String> errors) {
        super(message); this.code = code; this.errors = Map.copyOf(errors);
    }
    public String code() { return code; }
    public Map<String, String> errors() { return errors; }
}
