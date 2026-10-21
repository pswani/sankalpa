package com.sankalpa.application.conversation;

import java.time.*;
import java.time.temporal.ChronoUnit;
import java.util.*;

/** Untrusted plan input. Canonical expansion and bounds belong to application code. */
public record BatchSessionPlan(Mode mode, LocalDate from, LocalDate through, LocalTime localTime,
                               List<LocalDateTime> occurredAt, boolean recordingTimeSuggested) {
    public BatchSessionPlan(Mode mode, LocalDate from, LocalDate through, LocalTime localTime, List<LocalDateTime> occurredAt) {
        this(mode, from, through, localTime, occurredAt, false);
    }
    public enum Mode { DAILY_RANGE, EXPLICIT_TIMESTAMPS }
    public static final int MAX_ENTRIES = 30;
    public BatchSessionPlan { occurredAt = occurredAt == null ? null : List.copyOf(occurredAt); }
    public List<LocalDateTime> expand() {
        if (mode == null) invalid();
        List<LocalDateTime> dates;
        if (mode == Mode.DAILY_RANGE) {
            if (from == null || through == null || localTime == null || occurredAt != null || through.isBefore(from)) invalid();
            long count = ChronoUnit.DAYS.between(from, through) + 1;
            bound(count);
            dates = java.util.stream.IntStream.range(0, (int) count).mapToObj(i -> from.plusDays(i).atTime(localTime)).toList();
        } else {
            if (from != null || through != null || localTime != null || occurredAt == null) invalid();
            bound(occurredAt.size());
            if (occurredAt.stream().anyMatch(Objects::isNull)) invalid();
            dates = occurredAt.stream().sorted().toList();
        }
        if (new HashSet<>(dates).size() != dates.size()) invalid();
        return dates;
    }
    private static void bound(long count) {
        if (count > MAX_ENTRIES) throw new ConversationFailure("BATCH_TOO_LARGE",
                "That request contains " + count + " entries. Choose a range of at most 30 entries to confirm first.");
        if (count < 1) invalid();
    }
    private static void invalid() {
        throw new ConversationFailure("BATCH_INVALID_ENTRY", "Specify a valid date range and exact time, or 1–30 distinct timestamps.");
    }
}
