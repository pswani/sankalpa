package com.sankalpa.application;
public final class ExtensionClaimConflict extends RuntimeException {
    public ExtensionClaimConflict(Throwable cause) { super("Concurrent extension identity/source claim", cause); }
}
