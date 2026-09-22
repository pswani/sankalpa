package com.sankalpa.adapter;

import com.sankalpa.adapter.out.persistence.JdbcSankalpaPersistenceAdapter;
import com.sankalpa.application.ConcurrentModificationException;
import com.sankalpa.domain.*;
import com.sankalpa.domain.commitment.Commitment;
import com.sankalpa.domain.commitment.PeriodUnit;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.test.context.ActiveProfiles;
import org.springframework.transaction.annotation.Transactional;

import java.time.LocalDate;
import java.time.LocalDateTime;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

@SpringBootTest
@ActiveProfiles("test")
@Transactional
class JdbcPersistenceIntegrationTest {
    @Autowired JdbcSankalpaPersistenceAdapter adapter;
    @Autowired JdbcTemplate jdbc;

    @BeforeEach
    void clean() {
        jdbc.update("DELETE FROM practice_session");
        jdbc.update("DELETE FROM sankalpa_lifecycle_transition");
        jdbc.update("DELETE FROM sankalpa");
    }

    @Test
    void roundTripsAggregateTransitionsAndSessions() {
        LocalDate start = LocalDate.of(2026, 1, 31);
        LocalDateTime declaredAt = LocalDateTime.of(2026, 2, 2, 12, 0);
        Sankalpa original = Sankalpa.declare(SankalpaId.newId(), new Title("Vipassana"),
                new Description("Sit"), ActionType.MEDITATION,
                new Commitment(start, PeriodUnit.MONTH, 2, 6), declaredAt, declaredAt.toLocalDate());
        adapter.save(original);
        original.begin(start.atTime(7, 0), declaredAt);
        adapter.save(original);
        Session session = original.logSession(SessionId.newId(), start.atTime(8, 0), declaredAt);
        adapter.save(session);

        Sankalpa loaded = adapter.findById(original.id()).orElseThrow();
        assertThat(loaded.title()).isEqualTo(new Title("Vipassana"));
        assertThat(loaded.commitment().endDate()).contains(LocalDate.of(2026, 7, 30));
        assertThat(loaded.lifecycle().transitions()).hasSize(1);
        assertThat(loaded.lifecycle().transitions().getFirst().effectiveAt()).isEqualTo(start.atTime(7, 0));
        assertThat(adapter.findForSankalpa(original.id(), start, start)).containsExactly(session);
    }

    @Test
    void normalizedSchemaDoesNotStoreDerivedEndDate() {
        Integer endDateColumns = jdbc.queryForObject("""
                SELECT COUNT(*) FROM INFORMATION_SCHEMA.COLUMNS
                WHERE LOWER(TABLE_NAME) = 'sankalpa' AND LOWER(COLUMN_NAME) = 'end_date'
                """, Integer.class);
        assertThat(endDateColumns).isZero();

        Integer foreignKeys = jdbc.queryForObject("""
                SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLE_CONSTRAINTS
                WHERE LOWER(TABLE_NAME) IN ('practice_session', 'sankalpa_lifecycle_transition')
                  AND CONSTRAINT_TYPE = 'FOREIGN KEY'
                """, Integer.class);
        assertThat(foreignKeys).isEqualTo(2);
    }

    @Test
    void paginatesSessionsNewestFirstAndReportsTotal() {
        LocalDate start = LocalDate.of(2026, 3, 1);
        LocalDateTime now = start.plusDays(1).atStartOfDay();
        Sankalpa sankalpa = Sankalpa.declare(SankalpaId.newId(), new Title("Walk"),
                new Description(""), ActionType.PHYSICAL_ACTIVITY,
                new Commitment(start, PeriodUnit.DAY, 1, null), now, now.toLocalDate());
        adapter.save(sankalpa);
        sankalpa.begin(start.atStartOfDay(), now);
        adapter.save(sankalpa);
        Session first = sankalpa.logSession(SessionId.newId(), start.atTime(8, 0), now);
        Session second = sankalpa.logSession(SessionId.newId(), start.atTime(9, 0), now);
        Session third = sankalpa.logSession(SessionId.newId(), start.atTime(10, 0), now);
        adapter.save(first);
        adapter.save(second);
        adapter.save(third);

        assertThat(adapter.countForSankalpa(sankalpa.id(), null, null)).isEqualTo(3);
        assertThat(adapter.findPageForSankalpa(sankalpa.id(), null, null, 0, 2))
                .containsExactly(third, second);
        assertThat(adapter.findPageForSankalpa(sankalpa.id(), start, start, 2, 2))
                .containsExactly(first);
    }

    @Test
    void staleAggregateUpdateIsRejectedWithoutReplacingAuditHistory() {
        LocalDate start = LocalDate.of(2026, 4, 1);
        LocalDateTime now = start.atTime(12, 0);
        Sankalpa original = Sankalpa.declare(SankalpaId.newId(), new Title("Observe"),
                new Description(""), ActionType.OBSERVANCE,
                new Commitment(start, PeriodUnit.DAY, 1, null), now, start);
        adapter.save(original);
        Sankalpa first = adapter.findById(original.id()).orElseThrow();
        Sankalpa stale = adapter.findById(original.id()).orElseThrow();
        first.begin(start.atTime(8, 0), now);
        stale.begin(start.atTime(9, 0), now);

        adapter.save(first);

        assertThatThrownBy(() -> adapter.save(stale))
                .isInstanceOf(ConcurrentModificationException.class);
        Sankalpa stored = adapter.findById(original.id()).orElseThrow();
        assertThat(stored.lifecycle().transitions()).hasSize(1);
        assertThat(stored.lifecycle().transitions().getFirst().effectiveAt()).isEqualTo(start.atTime(8, 0));
    }
}
