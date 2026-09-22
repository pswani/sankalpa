package com.sankalpa.domain.lifecycle;

import java.util.EnumSet;

public enum LifecycleState {
    NOT_STARTED,
    IN_PROGRESS,
    PAUSED,
    COMPLETED_SUCCESSFULLY,
    COMPLETED_UNSUCCESSFULLY,
    STOPPED;

    public boolean canTransitionTo(LifecycleState target) {
        return switch (this) {
            case NOT_STARTED -> EnumSet.of(IN_PROGRESS, COMPLETED_SUCCESSFULLY,
                    COMPLETED_UNSUCCESSFULLY, STOPPED).contains(target);
            case IN_PROGRESS -> EnumSet.of(PAUSED, COMPLETED_SUCCESSFULLY,
                    COMPLETED_UNSUCCESSFULLY, STOPPED).contains(target);
            case PAUSED -> EnumSet.of(IN_PROGRESS, COMPLETED_SUCCESSFULLY,
                    COMPLETED_UNSUCCESSFULLY, STOPPED).contains(target);
            case COMPLETED_SUCCESSFULLY, COMPLETED_UNSUCCESSFULLY, STOPPED -> false;
        };
    }

    public boolean terminal() {
        return this == COMPLETED_SUCCESSFULLY || this == COMPLETED_UNSUCCESSFULLY || this == STOPPED;
    }
}
