package com.sankalpa.application.conversation;

/** Must cross the outer write boundary before a refusal may be recorded. */
public final class BatchRejection extends RuntimeException {
    private final String code;
    public BatchRejection(String code) { super(code); this.code = code; }
    public String code() { return code; }
}
