package com.sankalpa.application;

public final class ServiceInstanceMismatchException extends RuntimeException {
    public ServiceInstanceMismatchException() {
        super("The request was intended for a different Sankalpa service instance");
    }
}
