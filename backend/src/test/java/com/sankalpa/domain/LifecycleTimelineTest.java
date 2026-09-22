package com.sankalpa.domain;

import com.sankalpa.domain.lifecycle.LifecycleState;
import com.sankalpa.domain.lifecycle.LifecycleTimeline;
import org.junit.jupiter.api.Test;

import java.time.LocalDate;
import java.time.LocalDateTime;

import static org.assertj.core.api.Assertions.*;

class LifecycleTimelineTest {
    private static final LocalDate START = LocalDate.of(2026, 1, 1);
    private static final LocalDateTime NOW = LocalDateTime.of(2026, 1, 10, 12, 0);

    @Test
    void acceptsBackdatedBeginAndPreservesAuditTimes() {
        LifecycleTimeline timeline = new LifecycleTimeline();
        LocalDateTime effective = START.atTime(8, 0);
        timeline.begin(START, effective, NOW);
        assertThat(timeline.current()).isEqualTo(LifecycleState.IN_PROGRESS);
        assertThat(timeline.transitions().getFirst().effectiveAt()).isEqualTo(effective);
        assertThat(timeline.transitions().getFirst().recordedAt()).isEqualTo(NOW);
        assertThat(timeline.wasInProgressAt(LocalDateTime.of(2026, 1, 5, 12, 0))).isTrue();
    }

    @Test
    void rejectsFutureAndPreStartBegin() {
        assertThatThrownBy(() -> new LifecycleTimeline().begin(START, NOW.plusSeconds(1), NOW))
                .isInstanceOf(DomainException.class)
                .extracting("code").isEqualTo("TRANSITION_IN_FUTURE");
        assertThatThrownBy(() -> new LifecycleTimeline().begin(START, START.minusDays(1).atStartOfDay(), NOW))
                .isInstanceOf(DomainException.class)
                .extracting("code").isEqualTo("TRANSITION_BEFORE_START");
    }

    @Test
    void enforcesTransitionTableAndTerminalStates() {
        LifecycleTimeline timeline = new LifecycleTimeline();
        assertThatThrownBy(() -> timeline.transitionNow(LifecycleState.PAUSED, NOW))
                .isInstanceOf(DomainException.class);
        timeline.begin(START, NOW, NOW);
        timeline.transitionNow(LifecycleState.PAUSED, NOW.plusHours(1));
        timeline.transitionNow(LifecycleState.IN_PROGRESS, NOW.plusHours(2));
        timeline.transitionNow(LifecycleState.STOPPED, NOW.plusHours(3));
        assertThatThrownBy(() -> timeline.transitionNow(LifecycleState.IN_PROGRESS, NOW.plusHours(4)))
                .isInstanceOf(DomainException.class);
    }
}
