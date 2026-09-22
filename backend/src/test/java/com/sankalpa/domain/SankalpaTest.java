package com.sankalpa.domain;

import com.sankalpa.domain.commitment.Commitment;
import com.sankalpa.domain.commitment.PeriodUnit;
import org.junit.jupiter.api.Test;

import java.time.LocalDate;
import java.time.LocalDateTime;

import static org.assertj.core.api.Assertions.*;

class SankalpaTest {
    private static final LocalDate TODAY = LocalDate.of(2026, 6, 15);
    private static final LocalDate START = LocalDate.of(2026, 6, 1);
    private static final LocalDateTime NOW = TODAY.atTime(12, 0);

    private Sankalpa declared(Integer periods) {
        return Sankalpa.declare(SankalpaId.newId(), new Title("Meditate"), new Description("Daily"),
                ActionType.MEDITATION, new Commitment(START, PeriodUnit.DAY, 1, periods), NOW, TODAY);
    }

    @Test
    void rejectsStartMoreThanOneYearInPast() {
        assertThatThrownBy(() -> Sankalpa.declare(SankalpaId.newId(), new Title("Old"),
                new Description(""), ActionType.OBSERVANCE,
                new Commitment(TODAY.minusYears(1).minusDays(1), PeriodUnit.DAY, 1, null), NOW, TODAY))
                .isInstanceOf(DomainException.class)
                .extracting("code").isEqualTo("START_DATE_TOO_FAR_IN_PAST");
    }

    @Test
    void logsCoveredPastSessionAfterBackdatedBegin() {
        Sankalpa sankalpa = declared(null);
        sankalpa.begin(START.atStartOfDay(), NOW);
        Session session = sankalpa.logSession(SessionId.newId(), START.plusDays(2).atTime(8, 0), NOW);
        assertThat(session.occurredAt()).isEqualTo(START.plusDays(2).atTime(8, 0));
    }

    @Test
    void rejectsFutureOutsideAndInactiveSessions() {
        Sankalpa inactive = declared(null);
        assertThatThrownBy(() -> inactive.logSession(SessionId.newId(), START.atTime(12, 0), NOW))
                .isInstanceOf(DomainException.class)
                .extracting("code").isEqualTo("SANKALPA_NOT_IN_PROGRESS");

        Sankalpa active = declared(3);
        active.begin(START.atStartOfDay(), NOW);
        assertThatThrownBy(() -> active.logSession(SessionId.newId(), NOW.plusMinutes(1), NOW))
                .isInstanceOf(DomainException.class)
                .extracting("code").isEqualTo("SESSION_IN_FUTURE");
        assertThatThrownBy(() -> active.logSession(SessionId.newId(), START.plusDays(4).atTime(12, 0), NOW))
                .isInstanceOf(DomainException.class)
                .extracting("code").isEqualTo("SESSION_OUTSIDE_COMMITMENT");
    }

    @Test
    void aggregateRejectsMissingRequiredValuesWithoutRelyingOnHttpValidation() {
        Commitment commitment = new Commitment(START, PeriodUnit.DAY, 1, null);
        assertThatThrownBy(() -> Sankalpa.declare(SankalpaId.newId(), new Title("Practice"),
                new Description(""), null, commitment, NOW, TODAY))
                .isInstanceOf(DomainException.class)
                .extracting("code").isEqualTo("INVALID_SANKALPA");

        Sankalpa sankalpa = declared(null);
        assertThatThrownBy(() -> sankalpa.complete(null, NOW))
                .isInstanceOf(DomainException.class)
                .extracting("code").isEqualTo("INVALID_COMPLETION_OUTCOME");
        assertThatThrownBy(() -> sankalpa.logSession(null, START.atStartOfDay(), NOW))
                .isInstanceOf(DomainException.class)
                .extracting("code").isEqualTo("INVALID_SESSION");
    }
}
