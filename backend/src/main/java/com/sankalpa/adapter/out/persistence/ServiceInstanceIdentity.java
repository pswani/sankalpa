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
    private volatile UUID value;

    public ServiceInstanceIdentity(JdbcTemplate jdbc) { this.jdbc = jdbc; }

    @PostConstruct
    void initializeAndVerify() {
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
        verifyLedger();
    }

    public UUID value() { return value; }

    public void require(UUID expected) {
        if (expected == null || !value.equals(expected)) {
            throw new com.sankalpa.application.ServiceInstanceMismatchException();
        }
    }

    private void verifyLedger() {
        Integer inconsistent = jdbc.queryForObject("""
                SELECT COUNT(*) FROM (
                    SELECT i.session_id
                    FROM session_identity i
                    LEFT JOIN practice_session p ON p.id = i.session_id
                    WHERE (i.identity_state = 'ACTIVE' AND
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
