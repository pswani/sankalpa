package com.sankalpa.domain;

import com.sankalpa.domain.commitment.Commitment;
import com.sankalpa.domain.commitment.PeriodUnit;
import org.junit.jupiter.api.Test;

import java.time.LocalDate;

import static org.assertj.core.api.Assertions.*;

class CommitmentTest {
    @Test
    void derivesInclusiveEndDatesForEveryPeriodUnit() {
        LocalDate start = LocalDate.of(2026, 1, 10);
        assertThat(new Commitment(start, PeriodUnit.DAY, 1, 1).endDate()).contains(start);
        assertThat(new Commitment(start, PeriodUnit.WEEK, 1, 1).endDate())
                .contains(LocalDate.of(2026, 1, 16));
        assertThat(new Commitment(start, PeriodUnit.MONTH, 1, 1).endDate())
                .contains(LocalDate.of(2026, 2, 9));
        assertThat(new Commitment(start, PeriodUnit.YEAR, 1, 1).endDate())
                .contains(LocalDate.of(2027, 1, 9));
    }

    @Test
    void monthBoundariesRemainAnchoredAfterShortMonth() {
        Commitment commitment = new Commitment(LocalDate.of(2025, 1, 31), PeriodUnit.MONTH, 1, 4);
        assertThat(commitment.window(0).start()).isEqualTo(LocalDate.of(2025, 1, 31));
        assertThat(commitment.window(1).start()).isEqualTo(LocalDate.of(2025, 2, 28));
        assertThat(commitment.window(2).start()).isEqualTo(LocalDate.of(2025, 3, 31));
        assertThat(commitment.window(3).start()).isEqualTo(LocalDate.of(2025, 4, 30));
    }

    @Test
    void leapDayYearBoundaryReturnsToLeapDay() {
        Commitment commitment = new Commitment(LocalDate.of(2024, 2, 29), PeriodUnit.YEAR, 1, 5);
        assertThat(commitment.window(1).start()).isEqualTo(LocalDate.of(2025, 2, 28));
        assertThat(commitment.window(4).start()).isEqualTo(LocalDate.of(2028, 2, 29));
    }

    @Test
    void windowsAreRangeBoundedByTheirStartDates() {
        Commitment commitment = new Commitment(LocalDate.of(2026, 1, 1), PeriodUnit.WEEK, 2, null);
        assertThat(commitment.windowsStartingBetween(LocalDate.of(2026, 1, 8), LocalDate.of(2026, 1, 22)))
                .extracting(window -> window.start())
                .containsExactly(LocalDate.of(2026, 1, 8), LocalDate.of(2026, 1, 15), LocalDate.of(2026, 1, 22));
    }

    @Test
    void rejectsInvalidCountsAndRanges() {
        assertThatThrownBy(() -> new Commitment(LocalDate.now(), PeriodUnit.DAY, 0, null))
                .isInstanceOf(DomainException.class).hasMessageContaining("positive");
        Commitment commitment = new Commitment(LocalDate.now(), PeriodUnit.DAY, 1, null);
        assertThatThrownBy(() -> commitment.windowsStartingBetween(LocalDate.now(), LocalDate.now().minusDays(1)))
                .isInstanceOf(DomainException.class);
    }
}
