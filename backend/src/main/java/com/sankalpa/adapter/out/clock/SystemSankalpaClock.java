package com.sankalpa.adapter.out.clock;

import com.sankalpa.application.port.SankalpaClock;

import java.time.Clock;
import java.time.LocalDate;
import java.time.LocalDateTime;

public final class SystemSankalpaClock implements SankalpaClock {
    private final Clock clock;
    private final ThreadLocal<LocalDateTime> scoped = new ThreadLocal<>();

    public SystemSankalpaClock(Clock clock) { this.clock = clock; }
    @Override public LocalDateTime now() { return scoped.get() == null ? LocalDateTime.now(clock) : scoped.get(); }
    @Override public LocalDate today() { return now().toLocalDate(); }
    @Override public <T> T at(LocalDateTime moment, java.util.function.Supplier<T> action) {
        var previous = scoped.get(); scoped.set(moment);
        try { return action.get(); }
        finally { if (previous == null) scoped.remove(); else scoped.set(previous); }
    }
}
