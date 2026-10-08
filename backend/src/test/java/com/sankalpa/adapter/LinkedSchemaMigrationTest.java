package com.sankalpa.adapter;

import com.sankalpa.adapter.out.persistence.*;
import com.sankalpa.adapter.config.TransactionalSankalpaUseCases;
import com.sankalpa.application.*;
import com.sankalpa.application.port.SankalpaClock;
import com.sankalpa.domain.*;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;
import org.springframework.core.io.ClassPathResource;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.*;
import org.springframework.jdbc.datasource.init.ResourceDatabasePopulator;
import org.sqlite.SQLiteConfig;
import java.nio.file.*;
import java.time.*;
import java.util.*;
import static org.assertj.core.api.Assertions.*;

class LinkedSchemaMigrationTest {
    @TempDir Path directory;
    DriverManagerDataSource legacy() {
        SQLiteConfig config=new SQLiteConfig();config.enforceForeignKeys(true);config.setBusyTimeout(3000);
        var ds=new DriverManagerDataSource("jdbc:sqlite:"+directory.resolve("practice.db"),config.toProperties());
        new ResourceDatabasePopulator(new ClassPathResource("schema.sql")).execute(ds);
        return ds;
    }
    String seed(JdbcTemplate jdbc) {
        String id=UUID.randomUUID().toString();
        jdbc.update("INSERT INTO sankalpa VALUES (?, 'Vipassana', '', 'MEDITATION', '2026-07-01', 'DAY', 1, 40, 'IN_PROGRESS', '2026-07-01T00:00', 0)",id);
        jdbc.update("INSERT INTO sankalpa_lifecycle_transition VALUES (?,0,'NOT_STARTED','IN_PROGRESS','2026-07-01T00:00','2026-07-01T00:00')",id);
        String fact=UUID.randomUUID().toString();
        jdbc.update("INSERT INTO practice_session VALUES (?,?,'2026-07-10T08:00','2026-07-10T09:00')",fact,id);
        jdbc.update("INSERT INTO session_identity VALUES (?,?,'ACTIVE')",fact,id);
        jdbc.update("INSERT INTO service_metadata VALUES ('service_instance_id',?)",UUID.randomUUID().toString());
        return id;
    }
    @Test void populatedProductionMigrationPreservesIdentitiesAndBackup() throws Exception {
        var ds=legacy();var jdbc=new JdbcTemplate(ds);String id=seed(jdbc);
        String service=jdbc.queryForObject("SELECT metadata_value FROM service_metadata WHERE metadata_key='service_instance_id'",String.class);
        var migration=new LinkedSchemaMigration(ds);migration.migrate();migration.migrate();
        var adapter=new JdbcSankalpaPersistenceAdapter(jdbc);var root=adapter.findById(SankalpaId.parse(id)).orElseThrow();
        assertThat(root.seriesId()).isEqualTo(root.id());assertThat(root.extensionOf()).isEmpty();
        assertThat(root.lifecycle().transitions().getFirst().originSankalpaId()).isEqualTo(root.id());
        assertThat(adapter.scanCandidates(List.of(root.id()),null,null,null,100)).hasSize(1);
        assertThat(jdbc.queryForObject("SELECT metadata_value FROM service_metadata WHERE metadata_key='service_instance_id'",String.class)).isEqualTo(service);
        try (var files = Files.list(directory)) {
            var backups = files.filter(f -> f.getFileName().toString().contains("pre-linked")).toList();
            assertThat(backups).hasSize(1);
            var restored = new JdbcTemplate(new DriverManagerDataSource("jdbc:sqlite:" + backups.getFirst()));
            assertThat(restored.queryForObject("SELECT id FROM sankalpa", String.class)).isEqualTo(id);
            assertThat(restored.queryForObject("SELECT COUNT(*) FROM practice_session", Integer.class)).isEqualTo(1);
            assertThat(restored.queryForObject("SELECT metadata_value FROM service_metadata WHERE metadata_key='service_instance_id'", String.class)).isEqualTo(service);
            assertThat(restored.queryForList("PRAGMA table_info(sankalpa)")).noneMatch(row -> "series_id".equals(row.get("name")));
        }
        PracticeValidation.validate(adapter.findAll(),adapter.scanCandidates(List.of(root.id()),null,null,null,100));
        try(var c=ds.getConnection();var statement=c.createStatement();var result=statement.executeQuery("PRAGMA foreign_key_check")){assertThat(result.next()).isFalse();}
        var clock=new SankalpaClock(){public LocalDateTime now(){return LocalDateTime.of(2026,7,30,12,0);} public LocalDate today(){return now().toLocalDate();}};
        var serviceCases=new TransactionalSankalpaUseCases(new SankalpaService(adapter,adapter,clock),new DataSourceTransactionManager(ds));
        var child=serviceCases.extend(root.id(),SankalpaId.newId(),90,PracticeContract.LINKED_V1).sankalpa();
        migration.migrate();
        assertThat(adapter.findById(child.id()).orElseThrow().seriesId()).isEqualTo(root.id());
        assertThat(serviceCases.totalSessionCount(child.id())).isEqualTo(1);
        serviceCases.deleteSession(root.id(),adapter.scanCandidates(List.of(root.id()),null,null,null,1).getFirst().id(),PracticeContract.LINKED_V1);
        assertThat(serviceCases.totalSessionCount(child.id())).isZero();
    }
    @Test void failedMigrationRollsBackOriginalSchemaAndData() {
        var ds=legacy();var jdbc=new JdbcTemplate(ds);String id=seed(jdbc);
        jdbc.update("UPDATE sankalpa_lifecycle_transition SET recorded_at='corrupt' WHERE sankalpa_id=?",id);
        assertThatThrownBy(()->new LinkedSchemaMigration(ds).migrate()).isInstanceOf(IllegalStateException.class);
        assertThat(jdbc.queryForObject("SELECT recorded_at FROM sankalpa_lifecycle_transition",String.class)).isEqualTo("corrupt");
        assertThat(jdbc.queryForObject("SELECT COUNT(*) FROM service_metadata WHERE metadata_key='linked_extensions_schema'",Integer.class)).isZero();
        assertThat(jdbc.queryForList("PRAGMA table_info(sankalpa)")).noneMatch(row->"series_id".equals(row.get("name")));
        assertThat(jdbc.queryForObject("SELECT COUNT(*) FROM practice_session",Integer.class)).isEqualTo(1);
    }
    @Test void unknownSchemaAndUnmarkedPartialSchemaFailClosed() {
        var ds=legacy();var jdbc=new JdbcTemplate(ds);
        jdbc.update("INSERT INTO service_metadata VALUES ('linked_extensions_schema','999')");
        assertThatThrownBy(()->new LinkedSchemaMigration(ds).migrate()).isInstanceOf(IllegalStateException.class);
        jdbc.update("DELETE FROM service_metadata WHERE metadata_key='linked_extensions_schema'");
        jdbc.execute("ALTER TABLE sankalpa ADD series_id VARCHAR(36)");
        assertThatThrownBy(()->new LinkedSchemaMigration(ds).migrate()).isInstanceOf(IllegalStateException.class);
    }
    @Test void childAndHistoryRollbackTogetherOnStorageFailure() throws Exception {
        var ds=legacy();var jdbc=new JdbcTemplate(ds);String id=seed(jdbc);new LinkedSchemaMigration(ds).migrate();
        var adapter=new JdbcSankalpaPersistenceAdapter(jdbc);
        var clock=new SankalpaClock(){public LocalDateTime now(){return LocalDateTime.of(2026,7,30,12,0);} public LocalDate today(){return now().toLocalDate();}};
        var service=new TransactionalSankalpaUseCases(new SankalpaService(adapter,adapter,clock),new DataSourceTransactionManager(ds));
        long revision=adapter.readRevision();
        jdbc.execute("CREATE TRIGGER fail_child_history BEFORE INSERT ON sankalpa_lifecycle_transition WHEN NEW.sankalpa_id <> '"+id+"' BEGIN SELECT RAISE(ABORT,'injected history failure'); END");
        assertThatThrownBy(()->service.extend(SankalpaId.parse(id),SankalpaId.newId(),90,PracticeContract.LINKED_V1)).isInstanceOf(RuntimeException.class);
        assertThat(adapter.findAll()).hasSize(1);assertThat(adapter.readRevision()).isEqualTo(revision);
        assertThat(jdbc.queryForObject("SELECT COUNT(*) FROM sankalpa_lifecycle_transition",Integer.class)).isEqualTo(1);
    }
    @Test void overlappingSQLiteExtensionsSerializeAndRetryWholeTransactions() throws Exception {
        var ds = legacy();
        var jdbc = new JdbcTemplate(ds);
        String root = seed(jdbc);
        new LinkedSchemaMigration(ds).migrate();
        var barrier = new java.util.concurrent.CyclicBarrier(2);
        var seen = java.util.concurrent.ConcurrentHashMap.<Long>newKeySet();
        var adapter = new JdbcSankalpaPersistenceAdapter(jdbc) {
            @Override public Optional<Sankalpa> findById(SankalpaId id) {
                var value = super.findById(id);
                if (seen.add(Thread.currentThread().threadId())) {
                    try { barrier.await(5, java.util.concurrent.TimeUnit.SECONDS); }
                    catch (Exception failure) { throw new IllegalStateException(failure); }
                }
                return value;
            }
        };
        var clock = new SankalpaClock() {
            public LocalDateTime now() { return LocalDateTime.of(2026, 7, 30, 12, 0); }
            public LocalDate today() { return now().toLocalDate(); }
        };
        var service = new TransactionalSankalpaUseCases(new SankalpaService(adapter, adapter, clock),
                new DataSourceTransactionManager(ds));
        var pool = java.util.concurrent.Executors.newFixedThreadPool(2);
        try {
            java.util.concurrent.Callable<Object> command = () -> {
                try { return service.extend(SankalpaId.parse(root), SankalpaId.newId(), 90, PracticeContract.LINKED_V1); }
                catch (PracticeException refusal) { return refusal; }
            };
            var one = pool.submit(command);
            var two = pool.submit(command);
            var outcomes = List.of(one.get(10, java.util.concurrent.TimeUnit.SECONDS), two.get(10, java.util.concurrent.TimeUnit.SECONDS));
            assertThat(outcomes.stream().filter(ExtensionResult.class::isInstance)).hasSize(1);
            var conflict = (PracticeException) outcomes.stream().filter(PracticeException.class::isInstance).findFirst().orElseThrow();
            assertThat(conflict.code()).isEqualTo("EXTENSION_ALREADY_EXISTS");
            var stored = new JdbcSankalpaPersistenceAdapter(jdbc);
            assertThat(stored.findAll()).hasSize(2);
            assertThat(stored.readRevision()).isEqualTo(1);
            assertThat(jdbc.queryForObject("SELECT COUNT(*) FROM sankalpa_lifecycle_transition", Integer.class)).isEqualTo(2);
        } finally { pool.shutdownNow(); }
    }

    @Test void semanticValidationFailureRollsBackMigrationBeforePublishingMarker() {
        var ds = legacy();
        var jdbc = new JdbcTemplate(ds);
        seed(jdbc);
        jdbc.update("UPDATE practice_session SET occurred_at='2026-06-01T08:00'");
        assertThatThrownBy(() -> new LinkedSchemaMigration(ds).migrate()).isInstanceOf(IllegalStateException.class);
        assertThat(jdbc.queryForList("PRAGMA table_info(sankalpa)")).noneMatch(row -> "series_id".equals(row.get("name")));
        assertThat(jdbc.queryForObject("SELECT COUNT(*) FROM service_metadata WHERE metadata_key='linked_extensions_schema'", Integer.class)).isZero();
    }

    @Test void revisionFailureRollsBackFactAndIdentityTogether() throws Exception {
        var ds = legacy();
        var jdbc = new JdbcTemplate(ds);
        String root = seed(jdbc);
        new LinkedSchemaMigration(ds).migrate();
        var adapter = new JdbcSankalpaPersistenceAdapter(jdbc);
        var clock = new SankalpaClock() {
            public LocalDateTime now() { return LocalDateTime.of(2026, 7, 30, 12, 0); }
            public LocalDate today() { return now().toLocalDate(); }
        };
        var service = new TransactionalSankalpaUseCases(new SankalpaService(adapter, adapter, clock), new DataSourceTransactionManager(ds));
        jdbc.execute("CREATE TRIGGER fail_revision BEFORE UPDATE ON service_metadata WHEN OLD.metadata_key='practice_revision' BEGIN SELECT RAISE(ABORT,'injected revision failure'); END");
        var id = SessionId.newId();
        assertThatThrownBy(() -> service.logSession(SankalpaId.parse(root), id, clock.now(), PracticeContract.LINKED_V1)).isInstanceOf(RuntimeException.class);
        assertThat(adapter.findById(id)).isEmpty();
        assertThat(adapter.findIdentity(id)).isEmpty();
        assertThat(adapter.readRevision()).isZero();
    }

    @Test void overlappingSQLitePauseAndExtensionCopyACommittedTimeline() throws Exception {
        var ds = legacy();
        var jdbc = new JdbcTemplate(ds);
        String root = seed(jdbc);
        new LinkedSchemaMigration(ds).migrate();
        var barrier = new java.util.concurrent.CyclicBarrier(2);
        var seen = java.util.concurrent.ConcurrentHashMap.<Long>newKeySet();
        var adapter = new JdbcSankalpaPersistenceAdapter(jdbc) {
            @Override public Optional<Sankalpa> findById(SankalpaId id) {
                var value = super.findById(id);
                if (seen.add(Thread.currentThread().threadId())) {
                    try { barrier.await(5, java.util.concurrent.TimeUnit.SECONDS); }
                    catch (Exception failure) { throw new IllegalStateException(failure); }
                }
                return value;
            }
        };
        var clock = new SankalpaClock() {
            public LocalDateTime now() { return LocalDateTime.of(2026, 7, 30, 12, 0); }
            public LocalDate today() { return now().toLocalDate(); }
        };
        var service = new TransactionalSankalpaUseCases(new SankalpaService(adapter, adapter, clock), new DataSourceTransactionManager(ds));
        var pool = java.util.concurrent.Executors.newFixedThreadPool(2);
        try {
            var extension = pool.submit(() -> service.extend(SankalpaId.parse(root), SankalpaId.newId(), 90, PracticeContract.LINKED_V1));
            var pause = pool.submit(() -> service.pause(SankalpaId.parse(root), PracticeContract.LINKED_V1));
            var child = extension.get(10, java.util.concurrent.TimeUnit.SECONDS).sankalpa();
            pause.get(10, java.util.concurrent.TimeUnit.SECONDS);
            var stored = new JdbcSankalpaPersistenceAdapter(jdbc);
            var original = stored.findById(SankalpaId.parse(root)).orElseThrow();
            assertThat(original.lifecycle().current()).isEqualTo(com.sankalpa.domain.lifecycle.LifecycleState.PAUSED);
            assertThat(child.lifecycle().transitions()).isEqualTo(original.lifecycle().transitions().subList(0, child.lifecycle().transitions().size()));
            assertThat(stored.readRevision()).isEqualTo(2);
            PracticeValidation.validate(stored.findAll(), stored.scanCandidates(List.of(original.id(), child.id()), null, null, null, 100));
        } finally { pool.shutdownNow(); }
    }

}
