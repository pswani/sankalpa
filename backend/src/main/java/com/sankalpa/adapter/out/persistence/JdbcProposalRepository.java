package com.sankalpa.adapter.out.persistence;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.sankalpa.application.conversation.Proposal;
import com.sankalpa.application.conversation.ProposalRepository;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Repository;

import java.sql.ResultSet;
import java.sql.SQLException;
import java.time.LocalDateTime;
import java.util.Optional;
import java.util.UUID;

@Repository
public class JdbcProposalRepository implements ProposalRepository {
    private final JdbcTemplate jdbc;
    private final ObjectMapper json;

    public JdbcProposalRepository(JdbcTemplate jdbc, ObjectMapper json) {
        this.jdbc = jdbc;
        this.json = json;
    }

    @Override
    public void insert(Proposal p) {
        jdbc.update("""
                INSERT INTO assistant_proposal
                  (proposal_id, thread_id, source_run_id, kind, schema_version, payload_json,
                   status, confirmation_id, result_resource_id, failure_code,
                   created_at, expires_at, resolved_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, text(p.id()), text(p.threadId()), text(p.sourceRunId()), p.kind().name(),
                p.schemaVersion(), payloadJson(p), p.status().name(), text(p.confirmationId()),
                text(p.resultResourceId()), p.failureCode(), text(p.createdAt()),
                text(p.expiresAt()), text(p.resolvedAt()));
    }

    @Override
    public Optional<Proposal> findBySourceRunId(UUID sourceRunId) {
        return query("SELECT * FROM assistant_proposal WHERE source_run_id = ?", sourceRunId);
    }

    @Override
    public Optional<Proposal> findPendingByThread(UUID threadId) {
        return query("SELECT * FROM assistant_proposal WHERE thread_id = ? AND status = 'PENDING'", threadId);
    }

    @Override
    public Optional<Proposal> findByIdForUpdate(UUID proposalId) {
        int matched = jdbc.update("UPDATE assistant_proposal SET status = status WHERE proposal_id = ?",
                proposalId.toString());
        return matched == 0 ? Optional.empty()
                : query("SELECT * FROM assistant_proposal WHERE proposal_id = ?", proposalId);
    }

    @Override
    public void update(Proposal p) {
        int updated = jdbc.update("""
                UPDATE assistant_proposal
                SET status = ?, confirmation_id = ?, result_resource_id = ?, failure_code = ?, resolved_at = ?
                WHERE proposal_id = ?
                """, p.status().name(), text(p.confirmationId()), text(p.resultResourceId()),
                p.failureCode(), text(p.resolvedAt()), p.id().toString());
        if (updated != 1) throw new IllegalStateException("Proposal disappeared during resolution");
    }

    private Optional<Proposal> query(String sql, UUID id) {
        return jdbc.query(sql, (rs, rowNum) -> map(rs), id.toString()).stream().findFirst();
    }

    private Proposal map(ResultSet rs) throws SQLException {
        Proposal.Kind kind = Proposal.Kind.valueOf(rs.getString("kind"));
        Class<? extends Proposal.Payload> payloadType = kind == Proposal.Kind.LOG_SESSION
                ? Proposal.LogSessionPayload.class : Proposal.DeclareSankalpaPayload.class;
        try {
            return new Proposal(UUID.fromString(rs.getString("proposal_id")),
                    UUID.fromString(rs.getString("thread_id")),
                    UUID.fromString(rs.getString("source_run_id")), kind,
                    rs.getInt("schema_version"),
                    json.readValue(rs.getString("payload_json"), payloadType),
                    Proposal.Status.valueOf(rs.getString("status")),
                    uuid(rs.getString("confirmation_id")), uuid(rs.getString("result_resource_id")),
                    rs.getString("failure_code"), LocalDateTime.parse(rs.getString("created_at")),
                    LocalDateTime.parse(rs.getString("expires_at")), time(rs.getString("resolved_at")));
        } catch (JsonProcessingException | IllegalArgumentException e) {
            throw new SQLException("Invalid stored assistant proposal", e);
        }
    }

    private String payloadJson(Proposal p) {
        try { return json.writeValueAsString(p.payload()); }
        catch (JsonProcessingException e) { throw new IllegalStateException("Cannot encode proposal", e); }
    }

    private static String text(Object value) { return value == null ? null : value.toString(); }
    private static UUID uuid(String value) { return value == null ? null : UUID.fromString(value); }
    private static LocalDateTime time(String value) { return value == null ? null : LocalDateTime.parse(value); }
}
