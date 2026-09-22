package com.sankalpa.adapter.out.clock;

import com.sankalpa.application.port.SankalpaClock;

import java.time.Clock;
import java.time.LocalDate;
import java.time.LocalDateTime;

public final class SystemSankalpaClock implements SankalpaClock {
    private final Clock clock;

    public SystemSankalpaClock(Clock clock) { this.clock = clock; }
    @Override public LocalDateTime now() { return LocalDateTime.now(clock); }
    @Override public LocalDate today() { return LocalDate.now(clock); }
}
