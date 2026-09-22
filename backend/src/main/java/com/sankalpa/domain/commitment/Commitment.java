package com.sankalpa.domain.commitment;

import com.sankalpa.domain.DomainException;

import java.time.LocalDate;
import java.util.ArrayList;
import java.util.List;
import java.util.Optional;

public record Commitment(
        LocalDate startDate,
        PeriodUnit periodUnit,
        int timesPerPeriod,
        Integer periodCount
) {
    public Commitment {
        if (startDate == null || periodUnit == null) {
            throw new IllegalArgumentException("Start date and period unit are required");
        }
        if (timesPerPeriod <= 0) {
            throw new DomainException("INVALID_TIMES_PER_PERIOD", "Times per period must be positive");
        }
        if (periodCount != null && periodCount <= 0) {
            throw new DomainException("INVALID_PERIOD_COUNT", "Period count must be positive when provided");
        }
    }

    public Optional<LocalDate> endDate() {
        return periodCount == null
                ? Optional.empty()
                : Optional.of(boundary(periodCount).minusDays(1));
    }

    public boolean covers(LocalDate date) {
        return !date.isBefore(startDate) && endDate().map(end -> !date.isAfter(end)).orElse(true);
    }

    public PeriodWindow window(int index) {
        if (index < 0 || (periodCount != null && index >= periodCount)) {
            throw new IllegalArgumentException("Period index is outside the commitment");
        }
        return new PeriodWindow(index, boundary(index), boundary(index + 1).minusDays(1));
    }

    public List<PeriodWindow> windowsStartingBetween(LocalDate from, LocalDate until) {
        if (from == null || until == null || from.isAfter(until)) {
            throw new DomainException("INVALID_DATE_RANGE", "from must be on or before until");
        }
        List<PeriodWindow> windows = new ArrayList<>();
        for (int i = 0; periodCount == null || i < periodCount; i++) {
            PeriodWindow window = window(i);
            if (window.start().isAfter(until)) break;
            if (!window.start().isBefore(from)) windows.add(window);
        }
        return List.copyOf(windows);
    }

    private LocalDate boundary(int index) {
        return switch (periodUnit) {
            case DAY -> startDate.plusDays(index);
            case WEEK -> startDate.plusWeeks(index);
            case MONTH -> startDate.plusMonths(index);
            case YEAR -> startDate.plusYears(index);
        };
    }
}
