package com.sankalpa.application.conversation;

public final class ConversationFailure extends RuntimeException {
    private final String code;
    private final java.util.Map<String, String> details;

    public ConversationFailure(String code, String message) {
        this(code, message, java.util.Map.of());
    }

    public ConversationFailure(String code, String message, java.util.Map<String, String> details) {
        super(message);
        this.code = code;
        this.details = java.util.Map.copyOf(details);
    }

    public String code() { return code; }
    public java.util.Map<String, String> details() { return details; }
}
