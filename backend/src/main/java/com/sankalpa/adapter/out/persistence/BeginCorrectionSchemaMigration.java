package com.sankalpa.adapter.out.persistence;

import org.springframework.stereotype.Component;
import org.springframework.jdbc.core.JdbcTemplate;

@Component
@org.springframework.context.annotation.DependsOn("linkedSchemaMigration")
@org.springframework.boot.autoconfigure.condition.ConditionalOnProperty(name="sankalpa.persistence", havingValue="sqlite", matchIfMissing=true)
public final class BeginCorrectionSchemaMigration {
    public BeginCorrectionSchemaMigration(JdbcTemplate jdbc) {
        boolean exists = Boolean.TRUE.equals(jdbc.execute((org.springframework.jdbc.core.ConnectionCallback<Boolean>) connection -> {
            try (var columns = connection.getMetaData().getColumns(null, null, "sankalpa_lifecycle_transition", "begin_corrections_json")) {
                return columns.next();
            }
        }));
        if (!exists) jdbc.execute("ALTER TABLE sankalpa_lifecycle_transition ADD COLUMN begin_corrections_json TEXT NOT NULL DEFAULT '[]'");
    }
}
