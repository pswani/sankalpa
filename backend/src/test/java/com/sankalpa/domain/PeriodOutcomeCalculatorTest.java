package com.sankalpa.domain;

import com.sankalpa.domain.commitment.*;
import com.sankalpa.domain.lifecycle.LifecycleState;
import com.sankalpa.domain.lifecycle.LifecycleTimeline;
import org.junit.jupiter.api.Test;

import java.time.LocalDate;
import java.time.LocalDateTime;
import java.util.List;

import static org.assertj.core.api.Assertions.assertThat;

class PeriodOutcomeCalculatorTest {
    private final PeriodOutcomeCalculator calculator = new PeriodOutcomeCalculator();
    private final SankalpaId id = SankalpaId.newId();

    @Test
    void extraSessionsStillSatisfyAndMissedIsNeverNegative() {
        LocalDate start = LocalDate.of(2026, 1, 1);
        Commitment commitment = new Commitment(start, PeriodUnit.DAY, 2, 1);
        LifecycleTimeline lifecycle = begun(start);
        List<Session> sessions = List.of(session(start, 8), session(start, 9), session(start, 10));
        PeriodOutcome result = calculator.calculate(commitment, lifecycle, sessions,
                start, start, start.plusDays(1)).getFirst();
        assertThat(result.standing()).isEqualTo(PeriodStanding.SATISFIED);
        assertThat(result.performed()).isEqualTo(3);
        assertThat(result.missed()).isZero();
    }

    @Test
    void derivesMissedShortfallForClosedWindow() {
        LocalDate start = LocalDate.of(2026, 1, 1);
        Commitment commitment = new Commitment(start, PeriodUnit.WEEK, 4, 1);
        PeriodOutcome result = calculator.calculate(commitment, begun(start), List.of(session(start, 8)),
                start, start, start.plusWeeks(1)).getFirst();
        assertThat(result.standing()).isEqualTo(PeriodStanding.UNSATISFIED);
        assertThat(result.missed()).isEqualTo(3);
    }

    @Test
    void fullyPausedWindowIsPausedButPartialPauseIsEvaluated() {
        LocalDate start = LocalDate.of(2026, 1, 1);
        Commitment commitment = new Commitment(start, PeriodUnit.DAY, 1, 2);
        LifecycleTimeline lifecycle = begun(start);
        lifecycle.transitionNow(LifecycleState.PAUSED, start.plusDays(1).atStartOfDay());
        List<PeriodOutcome> results = calculator.calculate(commitment, lifecycle, List.of(),
                start, start.plusDays(1), start.plusDays(3));
        assertThat(results.get(0).standing()).isEqualTo(PeriodStanding.UNSATISFIED);
        assertThat(results.get(1).standing()).isEqualTo(PeriodStanding.PAUSED);
        assertThat(results.get(1).missed()).isZero();
    }

    @Test
    void terminalTransitionExcludesInterruptedAndLaterWindows() {
        LocalDate start = LocalDate.of(2026, 1, 1);
        Commitment commitment = new Commitment(start, PeriodUnit.DAY, 1, 5);
        LifecycleTimeline lifecycle = begun(start);
        lifecycle.transitionNow(LifecycleState.STOPPED, start.plusDays(2).atTime(12, 0));
        List<PeriodOutcome> results = calculator.calculate(commitment, lifecycle, List.of(),
                start, start.plusDays(4), start.plusDays(10));
        assertThat(results).hasSize(2);
        assertThat(results).extracting(r -> r.window().index()).containsExactly(0, 1);
    }

    private LifecycleTimeline begun(LocalDate start) {
        LifecycleTimeline lifecycle = new LifecycleTimeline();
        lifecycle.begin(start, start.atStartOfDay(), start.atStartOfDay());
        return lifecycle;
    }

    private Session session(LocalDate date, int hour) {
        LocalDateTime at = date.atTime(hour, 0);
        return new Session(SessionId.newId(), id, at, at.plusHours(1));
    }
}
