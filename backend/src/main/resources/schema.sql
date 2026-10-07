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

CREATE TABLE IF NOT EXISTS assistant_proposal (
    proposal_id VARCHAR(36) PRIMARY KEY,
    thread_id VARCHAR(36) NOT NULL,
    source_run_id VARCHAR(36) NOT NULL UNIQUE,
    kind VARCHAR(32) NOT NULL CHECK (kind IN ('LOG_SESSION', 'DECLARE_SANKALPA')),
    schema_version INTEGER NOT NULL,
    payload_json TEXT NOT NULL,
    status VARCHAR(16) NOT NULL CHECK (status IN ('PENDING', 'EXECUTED', 'CANCELLED', 'EXPIRED', 'REJECTED')),
    confirmation_id VARCHAR(36) UNIQUE,
    result_resource_id VARCHAR(36),
    failure_code VARCHAR(64),
    created_at VARCHAR(30) NOT NULL,
    expires_at VARCHAR(30) NOT NULL,
    resolved_at VARCHAR(30)
);

CREATE INDEX IF NOT EXISTS idx_assistant_proposal_thread_status
    ON assistant_proposal(thread_id, status);

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
