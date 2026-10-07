package com.sankalpa.application.conversation;

public final class ConversationFailure extends RuntimeException {
    private final String code;

    public ConversationFailure(String code, String message) {
        super(message);
        this.code = code;
    }

    public String code() { return code; }
}
