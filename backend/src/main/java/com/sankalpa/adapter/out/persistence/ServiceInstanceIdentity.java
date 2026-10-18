package com.sankalpa.adapter.out.persistence;

import jakarta.annotation.PostConstruct;
import org.springframework.dao.DuplicateKeyException;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Component;

import java.util.List;
import java.util.UUID;

@Component
public final class ServiceInstanceIdentity {
    private static final String KEY = "service_instance_id";

    private final JdbcTemplate jdbc;
    private final JdbcSankalpaPersistenceAdapter practice;
    private volatile UUID value;
    private com.sankalpa.adapter.out.dynamodb.DynamoUnitOfWork dynamo;

    public ServiceInstanceIdentity(JdbcTemplate jdbc, JdbcSankalpaPersistenceAdapter practice) { this.jdbc = jdbc; this.practice = practice; }

    @org.springframework.beans.factory.annotation.Autowired
    public ServiceInstanceIdentity(org.springframework.beans.factory.ObjectProvider<JdbcTemplate> jdbc,
            org.springframework.beans.factory.ObjectProvider<JdbcSankalpaPersistenceAdapter> practice,
            org.springframework.beans.factory.ObjectProvider<com.sankalpa.adapter.out.dynamodb.DynamoUnitOfWork> dynamo) {
        this.jdbc = jdbc.getIfAvailable(); this.practice = practice.getIfAvailable(); this.dynamo = dynamo.getIfAvailable();
    }

    @PostConstruct
    void initializeAndVerify() {
        if (dynamo != null) { value = UUID.fromString(dynamo.metadata().get("serviceInstanceId").asText()); return; }
        List<String> stored = jdbc.query(
                "SELECT metadata_value FROM service_metadata WHERE metadata_key = ?",
                (rs, rowNum) -> rs.getString(1), KEY);
        if (stored.isEmpty()) {
            String generated = UUID.randomUUID().toString();
            try {
                jdbc.update("INSERT INTO service_metadata (metadata_key, metadata_value) VALUES (?, ?)",
                        KEY, generated);
            } catch (DuplicateKeyException ignored) {
                // A concurrent initializer won. Read its durable value below.
            }
            stored = jdbc.query(
                    "SELECT metadata_value FROM service_metadata WHERE metadata_key = ?",
                    (rs, rowNum) -> rs.getString(1), KEY);
        }
        if (stored.size() != 1) {
            throw new IllegalStateException("Exactly one service instance identity is required");
        }
        value = UUID.fromString(stored.getFirst());
        verifyLedger(jdbc);
        var vows=practice.findAll();
        com.sankalpa.application.PracticeValidation.validate(vows, practice.scanCandidates(vows.stream().map(v->v.id()).toList(),null,null,null,Integer.MAX_VALUE));
        practice.readRevision();
    }

    public UUID value() { return value; }

    public void require(UUID expected) {
        if (expected == null || !value.equals(expected)) {
            throw new com.sankalpa.application.ServiceInstanceMismatchException();
        }
    }

    static void verifyLedger(JdbcTemplate jdbc) {
        Integer invalidSequences = jdbc.queryForObject("""
                SELECT COUNT(*) FROM (
                    SELECT sankalpa_id FROM sankalpa_lifecycle_transition
                    GROUP BY sankalpa_id
                    HAVING MIN(sequence_number) <> 0 OR MAX(sequence_number) <> COUNT(*) - 1
                ) invalid_sequences
                """, Integer.class);
        if (invalidSequences == null || invalidSequences != 0) {
            throw new IllegalStateException("Lifecycle audit sequence is inconsistent");
        }
        Integer inconsistent = jdbc.queryForObject("""
                SELECT COUNT(*) FROM (
                    SELECT i.session_id
                    FROM session_identity i
                    LEFT JOIN practice_session p ON p.id = i.session_id
                    LEFT JOIN sankalpa s ON s.id = i.sankalpa_id
                    WHERE s.id IS NULL OR (i.identity_state = 'ACTIVE' AND
                           (p.id IS NULL OR p.sankalpa_id <> i.sankalpa_id))
                       OR (i.identity_state = 'DELETED' AND p.id IS NOT NULL)
                    UNION ALL
                    SELECT p.id
                    FROM practice_session p
                    LEFT JOIN session_identity i ON i.session_id = p.id
                    WHERE i.session_id IS NULL
                ) inconsistent_rows
                """, Integer.class);
        if (inconsistent == null || inconsistent != 0) {
            throw new IllegalStateException("Session identity ledger is inconsistent");
        }
    }
}
