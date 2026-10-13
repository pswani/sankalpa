package com.sankalpa.adapter.out.persistence;

import jakarta.annotation.PostConstruct;
import org.springframework.boot.sql.init.dependency.DependsOnDatabaseInitialization;
import org.springframework.stereotype.Component;
import javax.sql.DataSource;
import java.sql.*;
import java.time.LocalDateTime;
import java.time.format.DateTimeFormatter;
import java.util.*;

/** Versioned, atomic upgrade of the bootstrap schema. Never runs against an unknown version. */
@Component
@DependsOnDatabaseInitialization
@org.springframework.boot.autoconfigure.condition.ConditionalOnProperty(name="sankalpa.persistence", havingValue="sqlite", matchIfMissing=true)
public final class LinkedSchemaMigration {
    static final DateTimeFormatter TIMESTAMP = DateTimeFormatter.ofPattern("uuuu-MM-dd'T'HH:mm:ss.SSSSSSSSS");
    private final DataSource dataSource;
    public LinkedSchemaMigration(DataSource dataSource) { this.dataSource = dataSource; }

    @PostConstruct
    public synchronized void migrate() throws SQLException {
        try (Connection c = dataSource.getConnection()) {
            boolean sqlite = c.getMetaData().getDatabaseProductName().equalsIgnoreCase("SQLite");
            String marker = metadata(c, "linked_extensions_schema");
            if (marker != null) {
                if (!marker.equals("1")) throw new IllegalStateException("Unsupported linked extension schema");
                requireColumns(c); return;
            }
            if (hasColumn(c, "sankalpa", "series_id")) throw new IllegalStateException("Unmarked partial linked schema");
            if (sqlite) {
                backup(c);
                execute(c, "PRAGMA foreign_keys=OFF");
            }
            c.setAutoCommit(false);
            try {
                if (sqlite) rebuildSQLite(c); else alter(c);
                canonicalize(c, "practice_session", "id", "occurred_at", "logged_at");
                canonicalizeTransitions(c);
                execute(c, "CREATE INDEX IF NOT EXISTS idx_sankalpa_series ON sankalpa(series_id, id)");
                execute(c, "CREATE UNIQUE INDEX IF NOT EXISTS idx_sankalpa_extension ON sankalpa(extension_of)");
                execute(c, "CREATE INDEX IF NOT EXISTS idx_session_owner_cursor ON practice_session(sankalpa_id, occurred_at, id)");
                put(c, "practice_revision", "0"); put(c, "linked_extensions_schema", "1");
                if (sqlite) try (Statement s = c.createStatement(); ResultSet r = s.executeQuery("PRAGMA foreign_key_check")) {
                    if (r.next()) throw new IllegalStateException("Migration produced invalid references");
                }
                var jdbc = new org.springframework.jdbc.core.JdbcTemplate(
                        new org.springframework.jdbc.datasource.SingleConnectionDataSource(c, true));
                var practice = new JdbcSankalpaPersistenceAdapter(jdbc);
                var vows = practice.findAll();
                com.sankalpa.application.PracticeValidation.validate(vows, practice.scanCandidates(
                        vows.stream().map(v -> v.id()).toList(), null, null, null, Integer.MAX_VALUE));
                ServiceInstanceIdentity.verifyLedger(jdbc);
                c.commit();
            } catch (Exception failure) {
                c.rollback(); throw new IllegalStateException("Linked schema migration failed; original data retained", failure);
            } finally {
                c.setAutoCommit(true);
                if (sqlite) execute(c, "PRAGMA foreign_keys=ON");
            }
        }
    }

    private static void rebuildSQLite(Connection c) throws SQLException {
        execute(c, """
            CREATE TABLE sankalpa_linked_new (
              id VARCHAR(36) PRIMARY KEY, title VARCHAR(200) NOT NULL, description TEXT NOT NULL,
              action_type VARCHAR(32) NOT NULL, start_date VARCHAR(10) NOT NULL, period_unit VARCHAR(16) NOT NULL,
              times_per_period INTEGER NOT NULL CHECK(times_per_period BETWEEN 1 AND 99),
              period_count INTEGER CHECK(period_count IS NULL OR period_count BETWEEN 1 AND 3650),
              current_state VARCHAR(32) NOT NULL, declared_at VARCHAR(30) NOT NULL, version INTEGER NOT NULL DEFAULT 0,
              series_id VARCHAR(36) NOT NULL REFERENCES sankalpa(id),
              extension_of VARCHAR(36) REFERENCES sankalpa(id), CHECK(extension_of IS NULL OR extension_of <> id))
            """);
        execute(c, "INSERT INTO sankalpa_linked_new SELECT *, id, NULL FROM sankalpa");
        execute(c, "DROP TABLE sankalpa");
        execute(c, "ALTER TABLE sankalpa_linked_new RENAME TO sankalpa");
        execute(c, """
            CREATE TABLE transition_linked_new (
              sankalpa_id VARCHAR(36) NOT NULL REFERENCES sankalpa(id) ON DELETE CASCADE,
              sequence_number INTEGER NOT NULL, from_state VARCHAR(32) NOT NULL, to_state VARCHAR(32) NOT NULL,
              effective_at VARCHAR(30) NOT NULL, recorded_at VARCHAR(30) NOT NULL,
              origin_sankalpa_id VARCHAR(36) NOT NULL REFERENCES sankalpa(id),
              PRIMARY KEY(sankalpa_id, sequence_number))
            """);
        execute(c, "INSERT INTO transition_linked_new SELECT *, sankalpa_id FROM sankalpa_lifecycle_transition");
        execute(c, "DROP TABLE sankalpa_lifecycle_transition");
        execute(c, "ALTER TABLE transition_linked_new RENAME TO sankalpa_lifecycle_transition");
        execute(c, "CREATE INDEX IF NOT EXISTS idx_transition_sankalpa_effective ON sankalpa_lifecycle_transition(sankalpa_id,effective_at)");
    }
    private static void alter(Connection c) throws SQLException {
        execute(c, "ALTER TABLE sankalpa ADD series_id VARCHAR(36)");
        execute(c, "ALTER TABLE sankalpa ADD extension_of VARCHAR(36)");
        execute(c, "UPDATE sankalpa SET series_id=id");
        execute(c, "ALTER TABLE sankalpa ALTER COLUMN series_id SET NOT NULL");
        execute(c, "ALTER TABLE sankalpa ADD FOREIGN KEY(series_id) REFERENCES sankalpa(id)");
        execute(c, "ALTER TABLE sankalpa ADD FOREIGN KEY(extension_of) REFERENCES sankalpa(id)");
        execute(c, "ALTER TABLE sankalpa ADD CHECK(extension_of IS NULL OR extension_of <> id)");
        execute(c, "ALTER TABLE sankalpa_lifecycle_transition ADD origin_sankalpa_id VARCHAR(36)");
        execute(c, "UPDATE sankalpa_lifecycle_transition SET origin_sankalpa_id=sankalpa_id");
        execute(c, "ALTER TABLE sankalpa_lifecycle_transition ALTER COLUMN origin_sankalpa_id SET NOT NULL");
        execute(c, "ALTER TABLE sankalpa_lifecycle_transition ADD FOREIGN KEY(origin_sankalpa_id) REFERENCES sankalpa(id)");
    }
    private static void backup(Connection c) throws SQLException {
        try (Statement s=c.createStatement(); ResultSet count=s.executeQuery("SELECT COUNT(*) FROM sankalpa")) {
            count.next(); if (count.getLong(1)==0) return;
        }
        String path="";
        try (Statement s=c.createStatement(); ResultSet r=s.executeQuery("PRAGMA database_list")) {
            while(r.next()) if(r.getString("name").equals("main")) path=r.getString("file");
        }
        if (!path.isEmpty()) try (PreparedStatement p=c.prepareStatement("VACUUM INTO ?")) {
            p.setString(1,path+".pre-linked-"+UUID.randomUUID()+".db"); p.execute();
        }
    }
    private static void canonicalize(Connection c,String table,String key,String... columns) throws SQLException {
        List<String[]> rows=new ArrayList<>();
        try(Statement s=c.createStatement();ResultSet r=s.executeQuery("SELECT * FROM "+table)) {
            while(r.next()) { String[] row=new String[columns.length+1];row[0]=r.getString(key);
                for(int i=0;i<columns.length;i++) row[i+1]=TIMESTAMP.format(LocalDateTime.parse(r.getString(columns[i])));rows.add(row); }
        }
        String assignments=String.join(",",Arrays.stream(columns).map(col->col+"=?").toList());
        try(PreparedStatement p=c.prepareStatement("UPDATE "+table+" SET "+assignments+" WHERE "+key+"=?")) {
            for(String[] row:rows){for(int i=1;i<row.length;i++)p.setString(i,row[i]);p.setString(row.length,row[0]);p.executeUpdate();}
        }
    }
    private static void canonicalizeTransitions(Connection c) throws SQLException {
        record Row(String id,int sequence,String effective,String recorded) {}
        List<Row> rows=new ArrayList<>();
        try(Statement s=c.createStatement();ResultSet r=s.executeQuery("SELECT * FROM sankalpa_lifecycle_transition")) {
            while(r.next())rows.add(new Row(r.getString("sankalpa_id"),r.getInt("sequence_number"),
                    TIMESTAMP.format(LocalDateTime.parse(r.getString("effective_at"))),TIMESTAMP.format(LocalDateTime.parse(r.getString("recorded_at")))));
        }
        try(PreparedStatement p=c.prepareStatement("UPDATE sankalpa_lifecycle_transition SET effective_at=?, recorded_at=? WHERE sankalpa_id=? AND sequence_number=?")) {
            for(Row row:rows){p.setString(1,row.effective);p.setString(2,row.recorded);p.setString(3,row.id);p.setInt(4,row.sequence);p.executeUpdate();}
        }
    }
    private static String metadata(Connection c,String key) throws SQLException {
        try(PreparedStatement p=c.prepareStatement("SELECT metadata_value FROM service_metadata WHERE metadata_key=?")) {
            p.setString(1,key);try(ResultSet r=p.executeQuery()){return r.next()?r.getString(1):null;}
        }
    }
    private static void put(Connection c,String key,String value) throws SQLException {
        try(PreparedStatement p=c.prepareStatement("INSERT INTO service_metadata VALUES (?,?)")){p.setString(1,key);p.setString(2,value);p.executeUpdate();}
    }
    private static boolean hasColumn(Connection c,String table,String column) throws SQLException {
        try(Statement s=c.createStatement();ResultSet r=s.executeQuery("SELECT * FROM "+table+" WHERE 1=0")) {
            for(int i=1;i<=r.getMetaData().getColumnCount();i++)if(r.getMetaData().getColumnName(i).equalsIgnoreCase(column))return true;
            return false;
        }
    }
    private static void requireColumns(Connection c) throws SQLException {
        if(!hasColumn(c,"sankalpa","series_id") || !hasColumn(c,"sankalpa","extension_of")
                || !hasColumn(c,"sankalpa_lifecycle_transition","origin_sankalpa_id") || metadata(c,"practice_revision")==null)
            throw new IllegalStateException("Incomplete linked schema");
    }
    private static void execute(Connection c,String sql) throws SQLException {try(Statement s=c.createStatement()){s.execute(sql);}}
}
