package com.sankalpa.adapter;

import com.sankalpa.application.SankalpaUseCases;
import com.sankalpa.adapter.out.persistence.JdbcSankalpaPersistenceAdapter;
import com.sankalpa.domain.ActionType;
import com.sankalpa.domain.Sankalpa;
import com.sankalpa.domain.SessionId;
import com.sankalpa.domain.commitment.PeriodUnit;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;

import java.time.LocalDate;
import java.time.LocalDateTime;
import java.time.ZoneOffset;

import static org.assertj.core.api.Assertions.assertThat;

@SpringBootTest(properties = {
        "spring.main.web-application-type=none",
        "spring.datasource.url=jdbc:sqlite:target/sqlite-production-adapter-test.db",
        "spring.datasource.driver-class-name=org.sqlite.JDBC",
        "spring.datasource.hikari.maximum-pool-size=1",
        "spring.datasource.hikari.connection-init-sql=PRAGMA foreign_keys=ON",
        "spring.sql.init.mode=always",
        "sankalpa.timezone=UTC"
})
class SQLiteProductionAdapterTest {
    @Autowired SankalpaUseCases useCases;
    @Autowired JdbcSankalpaPersistenceAdapter adapter;
    @Autowired JdbcTemplate jdbc;

    @BeforeEach
    void clean() {
        jdbc.execute("DROP TRIGGER IF EXISTS prevent_transition_delete");
        jdbc.update("DELETE FROM practice_session");
        jdbc.update("DELETE FROM session_identity");
        jdbc.update("DELETE FROM sankalpa_lifecycle_transition");
        jdbc.update("DELETE FROM sankalpa");
    }

    @AfterEach
    void removeTestTrigger() {
        jdbc.execute("DROP TRIGGER IF EXISTS prevent_transition_delete");
    }

    @Test
    void writesAndReadsThroughTheProductionDriverAndTransactionAdapter() {
        Sankalpa declared = useCases.declare("Walk", "Thirty minutes", ActionType.PHYSICAL_ACTIVITY,
                LocalDate.now(), PeriodUnit.DAY, 1, null);
        Sankalpa begun = useCases.begin(declared.id(), null);
        useCases.logSession(declared.id(), SessionId.newId(),
                begun.lifecycle().transitions().getFirst().effectiveAt());

        assertThat(useCases.detail(declared.id()).title().value()).isEqualTo("Walk");
        assertThat(useCases.list()).extracting(item -> item.id()).containsExactly(declared.id());
        assertThat(useCases.sessions(declared.id(), null, null, 0, 10).totalElements()).isEqualTo(1);
    }

    @Test
    void sqliteRangeAndPaginationQueriesUseChronologicalTimestampOrdering() {
        LocalDateTime now = LocalDateTime.now(ZoneOffset.UTC);
        Sankalpa declared = useCases.declare("Walk", "", ActionType.PHYSICAL_ACTIVITY,
                now.toLocalDate(), PeriodUnit.DAY, 1, null);
        useCases.begin(declared.id(), now.toLocalDate().atStartOfDay());
        useCases.logSession(declared.id(), SessionId.newId(), now.minusMinutes(3));
        var middle = useCases.logSession(declared.id(), SessionId.newId(), now.minusMinutes(2)).session();
        var newest = useCases.logSession(declared.id(), SessionId.newId(), now.minusMinutes(1)).session();

        var page = useCases.sessions(declared.id(), now.toLocalDate(), now.toLocalDate(), 0, 2);

        assertThat(page.totalElements()).isEqualTo(3);
        assertThat(page.content()).containsExactly(newest, middle);
    }

    @Test
    void lifecycleAuditRowsAreAppendedWithoutDeletingRecordedFacts() {
        LocalDateTime now = LocalDateTime.now(ZoneOffset.UTC);
        Sankalpa declared = useCases.declare("Observe", "", ActionType.OBSERVANCE,
                now.toLocalDate(), PeriodUnit.DAY, 1, null);
        useCases.begin(declared.id(), now.toLocalDate().atStartOfDay());
        jdbc.execute("""
                CREATE TRIGGER prevent_transition_delete
                BEFORE DELETE ON sankalpa_lifecycle_transition
                BEGIN SELECT RAISE(FAIL, 'audit rows are immutable'); END
                """);

        useCases.pause(declared.id());

        Integer count = jdbc.queryForObject("""
                SELECT COUNT(*) FROM sankalpa_lifecycle_transition WHERE sankalpa_id = ?
                """, Integer.class, declared.id().toString());
        assertThat(count).isEqualTo(2);
        assertThat(adapter.findById(declared.id()).orElseThrow().lifecycle().transitions()).hasSize(2);
    }
}
