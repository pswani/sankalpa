package com.sankalpa.domain.commitment;

import java.time.LocalDate;

public record PeriodWindow(int index, LocalDate start, LocalDate end) {
    public PeriodWindow {
        if (index < 0 || start == null || end == null || end.isBefore(start)) {
            throw new IllegalArgumentException("Invalid period window");
        }
    }
}
