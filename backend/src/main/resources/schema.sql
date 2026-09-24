CREATE TABLE IF NOT EXISTS sankalpa (
    id VARCHAR(36) PRIMARY KEY,
    title VARCHAR(200) NOT NULL,
    description TEXT NOT NULL,
    action_type VARCHAR(32) NOT NULL,
    start_date VARCHAR(10) NOT NULL,
    period_unit VARCHAR(16) NOT NULL,
    times_per_period INTEGER NOT NULL CHECK (times_per_period BETWEEN 1 AND 99),
    period_count INTEGER CHECK (period_count IS NULL OR period_count BETWEEN 1 AND 3650),
    current_state VARCHAR(32) NOT NULL,
    declared_at VARCHAR(30) NOT NULL,
    version INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS sankalpa_lifecycle_transition (
    sankalpa_id VARCHAR(36) NOT NULL,
    sequence_number INTEGER NOT NULL,
    from_state VARCHAR(32) NOT NULL,
    to_state VARCHAR(32) NOT NULL,
    effective_at VARCHAR(30) NOT NULL,
    recorded_at VARCHAR(30) NOT NULL,
    PRIMARY KEY (sankalpa_id, sequence_number),
    FOREIGN KEY (sankalpa_id) REFERENCES sankalpa(id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS practice_session (
    id VARCHAR(36) PRIMARY KEY,
    sankalpa_id VARCHAR(36) NOT NULL,
    occurred_at VARCHAR(30) NOT NULL,
    logged_at VARCHAR(30) NOT NULL,
    FOREIGN KEY (sankalpa_id) REFERENCES sankalpa(id) ON DELETE RESTRICT
);

CREATE TABLE IF NOT EXISTS session_identity (
    session_id VARCHAR(36) PRIMARY KEY,
    sankalpa_id VARCHAR(36) NOT NULL,
    identity_state VARCHAR(16) NOT NULL CHECK (identity_state IN ('ACTIVE', 'DELETED')),
    FOREIGN KEY (sankalpa_id) REFERENCES sankalpa(id) ON DELETE RESTRICT
);

CREATE TABLE IF NOT EXISTS service_metadata (
    metadata_key VARCHAR(64) PRIMARY KEY,
    metadata_value VARCHAR(255) NOT NULL
);

INSERT INTO session_identity (session_id, sankalpa_id, identity_state)
SELECT p.id, p.sankalpa_id, 'ACTIVE'
FROM practice_session p
WHERE NOT EXISTS (
    SELECT 1 FROM session_identity i WHERE i.session_id = p.id
);

CREATE INDEX IF NOT EXISTS idx_session_sankalpa_occurred
    ON practice_session(sankalpa_id, occurred_at);
CREATE INDEX IF NOT EXISTS idx_transition_sankalpa_effective
    ON sankalpa_lifecycle_transition(sankalpa_id, effective_at);
