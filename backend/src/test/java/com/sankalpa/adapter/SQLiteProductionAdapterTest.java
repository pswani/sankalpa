package com.sankalpa.adapter;

import com.sankalpa.application.SankalpaUseCases;
import com.sankalpa.domain.ActionType;
import com.sankalpa.domain.Sankalpa;
import com.sankalpa.domain.commitment.PeriodUnit;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;

import java.time.LocalDate;

import static org.assertj.core.api.Assertions.assertThat;

@SpringBootTest(properties = {
        "spring.main.web-application-type=none",
        "spring.datasource.url=jdbc:sqlite:target/sqlite-production-adapter-test.db",
        "spring.datasource.driver-class-name=org.sqlite.JDBC",
        "spring.datasource.hikari.maximum-pool-size=1",
        "spring.datasource.hikari.connection-init-sql=PRAGMA foreign_keys=ON",
        "spring.sql.init.mode=always"
})
class SQLiteProductionAdapterTest {
    @Autowired SankalpaUseCases useCases;
    @Autowired JdbcTemplate jdbc;

    @BeforeEach
    void clean() {
        jdbc.update("DELETE FROM practice_session");
        jdbc.update("DELETE FROM sankalpa_lifecycle_transition");
        jdbc.update("DELETE FROM sankalpa");
    }

    @Test
    void writesAndReadsThroughTheProductionDriverAndTransactionAdapter() {
        Sankalpa declared = useCases.declare("Walk", "Thirty minutes", ActionType.PHYSICAL_ACTIVITY,
                LocalDate.now(), PeriodUnit.DAY, 1, null);
        Sankalpa begun = useCases.begin(declared.id(), null);
        useCases.logSession(declared.id(), begun.lifecycle().transitions().getFirst().effectiveAt());

        assertThat(useCases.detail(declared.id()).title().value()).isEqualTo("Walk");
        assertThat(useCases.list()).extracting(item -> item.id()).containsExactly(declared.id());
        assertThat(useCases.sessions(declared.id(), null, null, 0, 10).totalElements()).isEqualTo(1);
    }
}
