package com.sankalpa.adapter;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.sankalpa.adapter.out.persistence.*;
import com.sankalpa.adapter.config.*;
import com.sankalpa.adapter.out.clock.SystemSankalpaClock;
import com.sankalpa.application.*;
import com.sankalpa.application.conversation.*;
import com.sankalpa.domain.*;
import com.sankalpa.domain.commitment.PeriodUnit;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.io.TempDir;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.*;
import java.nio.file.*;
import java.time.*;
import java.util.*;
import static org.assertj.core.api.Assertions.*;

class BatchSqliteMigrationTest {
    @TempDir Path directory;
    @Test void legacyProposalMigrationPreservesRowsIndexesAndSupportsAtomicBatch() throws Exception {
        var datasource=new DriverManagerDataSource("jdbc:sqlite:"+directory.resolve("practice.db"));
        var jdbc=new JdbcTemplate(datasource);var manager=new DataSourceTransactionManager(datasource);
        String schema=Files.readString(Path.of("src/main/resources/schema.sql"));
        String legacy=schema.replace("'DECLARE_SANKALPA', 'LOG_SESSIONS'","'DECLARE_SANKALPA'");
        for(var statement:legacy.split(";")) if(!statement.isBlank()) jdbc.execute(statement);
        String id=UUID.randomUUID().toString();
        jdbc.update("INSERT INTO assistant_proposal (proposal_id,thread_id,source_run_id,kind,schema_version,payload_json,status,created_at,expires_at) VALUES (?,?,?,'DECLARE_SANKALPA',1,'{}','CANCELLED','2026-10-01T00:00','2026-10-01T00:30')",id,UUID.randomUUID().toString(),UUID.randomUUID().toString());
        new LinkedSchemaMigration(datasource).migrate();
        new BatchProposalMigration(jdbc,manager); new BatchProposalMigration(jdbc,manager);
        assertThat(jdbc.queryForObject("SELECT payload_json FROM assistant_proposal WHERE proposal_id=?",String.class,id)).isEqualTo("{}");
        assertThat(jdbc.queryForList("SELECT name FROM sqlite_master WHERE type='index' AND name='idx_assistant_proposal_thread_status'",String.class)).hasSize(1);
        var repo=new JdbcSankalpaPersistenceAdapter(jdbc);var tx=new JdbcUseCaseTransactions(manager);
        var clock=new SystemSankalpaClock(Clock.fixed(Instant.parse("2026-10-17T18:00:00Z"),ZoneOffset.UTC));
        var core=new SankalpaService(repo,repo,clock);var service=new TransactionalSankalpaUseCases(core,tx);
        var json=new ObjectMapper().findAndRegisterModules().disable(com.fasterxml.jackson.databind.SerializationFeature.WRITE_DATES_AS_TIMESTAMPS);
        var pr=new JdbcProposalRepository(jdbc,json);var proposals=new TransactionalConversationUseCases(new ProposalService(pr,core,clock,Duration.ofMinutes(30)),tx);
        var v=service.declare("Observe","",ActionType.OBSERVANCE,LocalDate.of(2026,9,1),PeriodUnit.DAY,1,100);
        service.begin(v.id(),LocalDateTime.of(2026,9,1,0,0));
        var plan=new BatchSessionPlan(BatchSessionPlan.Mode.DAILY_RANGE,LocalDate.of(2026,9,14),LocalDate.of(2026,10,13),LocalTime.of(20,0),null);
        var p=proposals.proposeSessions(UUID.randomUUID(),UUID.randomUUID(),v.id(),plan,PracticeContract.SINGLE_VOW_V1);
        // Database failure after 16 inserts must roll back all of them and keep the proposal pending.
        jdbc.execute("CREATE TRIGGER fail_batch BEFORE INSERT ON practice_session WHEN (SELECT COUNT(*) FROM practice_session)=16 BEGIN SELECT RAISE(FAIL,'injected failure'); END");
        var confirmation=UUID.randomUUID();
        assertThatThrownBy(()->proposals.confirm(p.threadId(),p.id(),confirmation,PracticeContract.SINGLE_VOW_V1,true)).isInstanceOf(RuntimeException.class);
        assertThat(service.totalSessionCount(v.id())).isZero();
        assertThat(jdbc.queryForObject("SELECT status FROM assistant_proposal WHERE proposal_id=?",String.class,p.id().toString())).isEqualTo("PENDING");
        jdbc.execute("DROP TRIGGER fail_batch");
        var first=proposals.confirm(p.threadId(),p.id(),confirmation,PracticeContract.SINGLE_VOW_V1,true);
        assertThat(first.proposal().batchResult().sessionIds()).hasSize(30);
        assertThat(proposals.confirm(p.threadId(),p.id(),confirmation,PracticeContract.SINGLE_VOW_V1,true).replay()).isTrue();
        assertThat(service.totalSessionCount(v.id())).isEqualTo(30);
    }
}
