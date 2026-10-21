package com.sankalpa.domain.lifecycle;

import java.time.LocalDateTime;

public record LifecycleTransition(
        LifecycleState from,
        LifecycleState to,
        LocalDateTime effectiveAt,
        LocalDateTime recordedAt,
        com.sankalpa.domain.SankalpaId originSankalpaId, java.util.List<BeginCorrection> beginCorrections
) {
    public LifecycleTransition(LifecycleState from, LifecycleState to, LocalDateTime effectiveAt,
                               LocalDateTime recordedAt, com.sankalpa.domain.SankalpaId origin) {
        this(from, to, effectiveAt, recordedAt, origin, java.util.List.of());
    }
    public LifecycleTransition(LifecycleState from, LifecycleState to, LocalDateTime effectiveAt, LocalDateTime recordedAt) {
        this(from, to, effectiveAt, recordedAt, null);
    }

    public LifecycleTransition {
        beginCorrections = beginCorrections == null ? java.util.List.of() : java.util.List.copyOf(beginCorrections);
        if (!beginCorrections.isEmpty()) {
            if (beginCorrections.size() != 1 || from != LifecycleState.NOT_STARTED || to != LifecycleState.IN_PROGRESS)
                throw new IllegalArgumentException("Only one initial Begin correction is supported");
            var correction = beginCorrections.getFirst();
            if (!correction.correctedEffectiveAt().equals(effectiveAt) || correction.previousEffectiveAt().isAfter(recordedAt)
                    || correction.recordedAt().isBefore(recordedAt))
                throw new IllegalArgumentException("Begin correction does not match its audit entry");
        }
        if (from == null || to == null || effectiveAt == null || recordedAt == null) {
            throw new IllegalArgumentException("Lifecycle transition fields are required");
        }
    }
}
