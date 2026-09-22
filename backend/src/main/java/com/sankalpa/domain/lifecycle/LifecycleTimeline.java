package com.sankalpa.domain.lifecycle;

import com.sankalpa.domain.DomainException;
import com.sankalpa.domain.commitment.PeriodWindow;

import java.time.LocalDate;
import java.time.LocalDateTime;
import java.time.LocalTime;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.List;
import java.util.Optional;

public final class LifecycleTimeline {
    private LifecycleState current;
    private final List<LifecycleTransition> transitions;

    public LifecycleTimeline() {
        this(LifecycleState.NOT_STARTED, List.of());
    }

    public LifecycleTimeline(LifecycleState current, List<LifecycleTransition> transitions) {
        this.current = current;
        this.transitions = new ArrayList<>(transitions);
    }

    public LifecycleState current() { return current; }
    public List<LifecycleTransition> transitions() { return List.copyOf(transitions); }

    public void begin(LocalDate startDate, LocalDateTime effectiveAt, LocalDateTime recordedAt) {
        if (effectiveAt.isAfter(recordedAt)) {
            throw new DomainException("TRANSITION_IN_FUTURE", "Begin cannot be effective in the future");
        }
        if (effectiveAt.toLocalDate().isBefore(startDate)) {
            throw new DomainException("TRANSITION_BEFORE_START", "Begin cannot be effective before the start date");
        }
        transitionTo(LifecycleState.IN_PROGRESS, effectiveAt, recordedAt);
    }

    public void transitionNow(LifecycleState target, LocalDateTime now) {
        transitionTo(target, now, now);
    }

    private void transitionTo(LifecycleState target, LocalDateTime effectiveAt, LocalDateTime recordedAt) {
        if (!current.canTransitionTo(target)) {
            throw new DomainException("INVALID_LIFECYCLE_TRANSITION",
                    "Cannot transition from " + current + " to " + target);
        }
        transitions.add(new LifecycleTransition(current, target, effectiveAt, recordedAt));
        current = target;
    }

    public LifecycleState stateAt(LocalDateTime at) {
        LifecycleState state = LifecycleState.NOT_STARTED;
        List<LifecycleTransition> ordered = transitions.stream()
                .sorted(Comparator.comparing(LifecycleTransition::effectiveAt))
                .toList();
        for (LifecycleTransition transition : ordered) {
            if (transition.effectiveAt().isAfter(at)) break;
            state = transition.to();
        }
        return state;
    }

    public boolean wasInProgressAt(LocalDateTime at) {
        return stateAt(at) == LifecycleState.IN_PROGRESS;
    }

    public boolean wasPausedThroughout(PeriodWindow window) {
        LocalDateTime start = window.start().atStartOfDay();
        LocalDateTime end = window.end().atTime(LocalTime.MAX);
        if (stateAt(start) != LifecycleState.PAUSED) return false;
        return transitions.stream()
                .noneMatch(t -> t.effectiveAt().isAfter(start)
                        && !t.effectiveAt().isAfter(end)
                        && t.to() != LifecycleState.PAUSED);
    }

    public Optional<LocalDateTime> terminalAt() {
        return transitions.stream()
                .filter(t -> t.to().terminal())
                .map(LifecycleTransition::effectiveAt)
                .findFirst();
    }
}
