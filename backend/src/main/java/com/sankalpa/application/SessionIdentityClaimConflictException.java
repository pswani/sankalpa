package com.sankalpa.application;

/** Signals that another transaction won the session-identity primary-key claim. */
public final class SessionIdentityClaimConflictException extends RuntimeException {
    public SessionIdentityClaimConflictException(Throwable cause) { super(cause); }
}
