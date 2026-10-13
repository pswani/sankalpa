package com.sankalpa.adapter.config;

import java.util.function.Supplier;

/** Adapter-owned boundary shared by practice and proposal use cases. */
public interface UseCaseTransactions {
    <T> T read(Supplier<T> action);
    <T> T write(Supplier<T> action);
}
