package com.sankalpa.domain.commitment;

import com.sankalpa.domain.Session;
import com.sankalpa.domain.lifecycle.LifecycleTimeline;

import java.time.LocalDate;
import java.time.LocalDateTime;
import java.time.LocalTime;
import java.util.ArrayList;
import java.util.List;

public final class PeriodOutcomeCalculator {
    public List<PeriodOutcome> calculate(Commitment commitment,
                                         LifecycleTimeline lifecycle,
                                         List<Session> sessions,
                                         LocalDate from,
                                         LocalDate until,
                                         LocalDate today) {
        List<PeriodOutcome> outcomes = new ArrayList<>();
        for (PeriodWindow window : commitment.windowsStartingBetween(from, until)) {
            LocalDateTime windowEnd = window.end().atTime(LocalTime.MAX);
            if (lifecycle.terminalAt().map(cutoff -> !windowEnd.isBefore(cutoff)).orElse(false)) break;

            int performed = (int) sessions.stream()
                    .filter(session -> !session.occurredAt().toLocalDate().isBefore(window.start()))
                    .filter(session -> !session.occurredAt().toLocalDate().isAfter(window.end()))
                    .count();
            int required = commitment.timesPerPeriod();
            boolean closed = window.end().isBefore(today);
            PeriodStanding standing;
            int missed;
            if (!closed) {
                standing = PeriodStanding.OPEN;
                missed = 0;
            } else if (lifecycle.wasPausedThroughout(window)) {
                standing = PeriodStanding.PAUSED;
                missed = 0;
            } else if (performed >= required) {
                standing = PeriodStanding.SATISFIED;
                missed = 0;
            } else {
                standing = PeriodStanding.UNSATISFIED;
                missed = required - performed;
            }
            outcomes.add(new PeriodOutcome(window, required, performed, missed, standing));
        }
        return List.copyOf(outcomes);
    }
}
