package com.sankalpa.adapter.out.persistence;

import org.springframework.boot.sql.init.dependency.DependsOnDatabaseInitialization;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Component;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.support.TransactionTemplate;

/** SQLite cannot widen a CHECK constraint in place. Preserve every old proposal and index. */
@Component
@DependsOnDatabaseInitialization
@ConditionalOnProperty(name="sankalpa.persistence", havingValue="sqlite", matchIfMissing=true)
public final class BatchProposalMigration {
    public BatchProposalMigration(JdbcTemplate jdbc, PlatformTransactionManager manager) {
        String product = jdbc.execute((org.springframework.jdbc.core.ConnectionCallback<String>)
                connection -> connection.getMetaData().getDatabaseProductName());
        if (!"SQLite".equals(product)) return;
        new TransactionTemplate(manager).executeWithoutResult(status -> {
            String definition = jdbc.queryForObject("SELECT sql FROM sqlite_master WHERE type='table' AND name='assistant_proposal'", String.class);
            if (definition == null || definition.contains("'LOG_SESSIONS'")) return;
            var indexes = jdbc.queryForList("SELECT sql FROM sqlite_master WHERE type='index' AND tbl_name='assistant_proposal' AND sql IS NOT NULL", String.class);
            String widened = definition.replaceFirst("(?i)CREATE TABLE(?: IF NOT EXISTS)?\\s+assistant_proposal", "CREATE TABLE assistant_proposal_batch_v2")
                    .replace("'DECLARE_SANKALPA'", "'DECLARE_SANKALPA', 'LOG_SESSIONS'");
            if (!widened.contains("'LOG_SESSIONS'")) throw new IllegalStateException("Unrecognized proposal schema");
            jdbc.execute(widened);
            jdbc.update("INSERT INTO assistant_proposal_batch_v2 SELECT * FROM assistant_proposal");
            jdbc.execute("DROP TABLE assistant_proposal");
            jdbc.execute("ALTER TABLE assistant_proposal_batch_v2 RENAME TO assistant_proposal");
            indexes.forEach(jdbc::execute);
        });
    }
}
