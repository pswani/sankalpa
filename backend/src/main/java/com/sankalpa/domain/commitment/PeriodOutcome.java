package com.sankalpa.domain.commitment;

public record PeriodOutcome(
        PeriodWindow window,
        int required,
        int performed,
        int missed,
        PeriodStanding standing
) {}
