package com.sankalpa.domain.commitment;

import com.sankalpa.domain.DomainException;

import java.time.DateTimeException;
import java.time.LocalDate;
import java.time.temporal.ChronoUnit;
import java.util.ArrayList;
import java.util.List;
import java.util.Optional;

public record Commitment(
        LocalDate startDate,
        PeriodUnit periodUnit,
        int timesPerPeriod,
        Integer periodCount
) {
    public static final int MAX_TIMES_PER_PERIOD = 99;
    public static final int MAX_PERIOD_COUNT = 3_650;
    public static final int MAX_OUTCOME_WINDOWS = 3_650;

    public Commitment {
        if (startDate == null || periodUnit == null) {
            throw new IllegalArgumentException("Start date and period unit are required");
        }
        if (timesPerPeriod <= 0) {
            throw new DomainException("INVALID_TIMES_PER_PERIOD", "Times per period must be positive");
        }
        if (timesPerPeriod > MAX_TIMES_PER_PERIOD) {
            throw new DomainException("INVALID_TIMES_PER_PERIOD",
                    "Times per period must not exceed " + MAX_TIMES_PER_PERIOD);
        }
        if (periodCount != null && periodCount <= 0) {
            throw new DomainException("INVALID_PERIOD_COUNT", "Period count must be positive when provided");
        }
        if (periodCount != null && periodCount > MAX_PERIOD_COUNT) {
            throw new DomainException("INVALID_PERIOD_COUNT",
                    "Period count must not exceed " + MAX_PERIOD_COUNT);
        }
        if (periodCount != null) {
            try {
                boundary(startDate, periodUnit, periodCount);
            } catch (DateTimeException exception) {
                throw new DomainException("INVALID_PERIOD_COUNT",
                        "Period count extends beyond the supported date range");
            }
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
        int firstIndex = firstBoundaryOnOrAfter(from);
        for (int i = firstIndex; periodCount == null || i < periodCount; i++) {
            PeriodWindow window = window(i);
            if (window.start().isAfter(until)) break;
            if (windows.size() == MAX_OUTCOME_WINDOWS) {
                throw new DomainException("PERIOD_RANGE_TOO_LARGE",
                        "Date range selects more than " + MAX_OUTCOME_WINDOWS + " period windows");
            }
            windows.add(window);
            if (i == Integer.MAX_VALUE) break;
        }
        return List.copyOf(windows);
    }

    private int firstBoundaryOnOrAfter(LocalDate date) {
        if (!date.isAfter(startDate)) return 0;
        long candidate = switch (periodUnit) {
            case DAY -> ChronoUnit.DAYS.between(startDate, date);
            case WEEK -> (ChronoUnit.DAYS.between(startDate, date) + 6) / 7;
            case MONTH -> (long) (date.getYear() - startDate.getYear()) * 12
                    + date.getMonthValue() - startDate.getMonthValue();
            case YEAR -> (long) date.getYear() - startDate.getYear();
        };
        if (candidate > Integer.MAX_VALUE) {
            throw new DomainException("PERIOD_RANGE_TOO_LARGE", "Date range is too far from the start date");
        }
        int index = Math.max(0, (int) candidate);
        try {
            while (boundary(index).isBefore(date)) index = Math.incrementExact(index);
            while (index > 0 && !boundary(index - 1).isBefore(date)) index--;
            return index;
        } catch (ArithmeticException | DateTimeException exception) {
            throw new DomainException("PERIOD_RANGE_TOO_LARGE", "Date range is outside supported bounds");
        }
    }

    private LocalDate boundary(int index) {
        try {
            return boundary(startDate, periodUnit, index);
        } catch (DateTimeException exception) {
            throw new DomainException("PERIOD_RANGE_TOO_LARGE", "Period boundary is outside supported bounds");
        }
    }

    private static LocalDate boundary(LocalDate startDate, PeriodUnit periodUnit, int index) {
        return switch (periodUnit) {
            case DAY -> startDate.plusDays(index);
            case WEEK -> startDate.plusWeeks(index);
            case MONTH -> startDate.plusMonths(index);
            case YEAR -> startDate.plusYears(index);
        };
    }
}
