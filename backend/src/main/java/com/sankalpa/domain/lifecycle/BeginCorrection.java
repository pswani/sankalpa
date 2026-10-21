package com.sankalpa.domain.lifecycle;

import java.time.LocalDateTime;
import java.util.UUID;

/** Immutable receipt retaining the original effective Begin when an explicit correction is approved. */
public record BeginCorrection(UUID id, LocalDateTime previousEffectiveAt,
                              LocalDateTime correctedEffectiveAt, LocalDateTime recordedAt) {
    public BeginCorrection {
        if (id == null || previousEffectiveAt == null || correctedEffectiveAt == null || recordedAt == null
                || !correctedEffectiveAt.isBefore(previousEffectiveAt) || recordedAt.isBefore(previousEffectiveAt))
            throw new IllegalArgumentException("Invalid Begin correction receipt");
    }
}
