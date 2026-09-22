package com.sankalpa.application;

public final class ConcurrentModificationException extends RuntimeException {
    public ConcurrentModificationException(String message) { super(message); }
}
