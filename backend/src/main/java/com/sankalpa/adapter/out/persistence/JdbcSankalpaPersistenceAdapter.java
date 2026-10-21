package com.sankalpa.adapter.out.persistence;

import com.sankalpa.application.ConcurrentModificationException;
import com.sankalpa.application.SessionIdentity;
import com.sankalpa.application.SessionIdentityClaimConflictException;
import com.sankalpa.application.SessionIdentityState;
import com.sankalpa.application.port.SankalpaRepository;
import com.sankalpa.application.port.SessionRepository;
import com.sankalpa.domain.*;
import com.sankalpa.domain.commitment.Commitment;
import com.sankalpa.domain.commitment.PeriodUnit;
import com.sankalpa.domain.lifecycle.LifecycleState;
import com.sankalpa.domain.lifecycle.LifecycleTimeline;
import com.sankalpa.domain.lifecycle.LifecycleTransition;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.dao.DuplicateKeyException;
import org.springframework.jdbc.core.RowCallbackHandler;
import org.springframework.stereotype.Repository;

import java.sql.ResultSet;
import java.sql.SQLException;
import java.time.LocalDate;
import java.time.LocalDateTime;
import java.time.LocalTime;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.Optional;

@Repository
@org.springframework.context.annotation.DependsOn("beginCorrectionSchemaMigration")
@org.springframework.boot.autoconfigure.condition.ConditionalOnProperty(name="sankalpa.persistence", havingValue="sqlite", matchIfMissing=true)
public class JdbcSankalpaPersistenceAdapter implements SankalpaRepository, SessionRepository {
    private final JdbcTemplate jdbc;
    private static final com.fasterxml.jackson.databind.ObjectMapper AUDIT_JSON = new com.fasterxml.jackson.databind.ObjectMapper()
            .findAndRegisterModules().disable(com.fasterxml.jackson.databind.SerializationFeature.WRITE_DATES_AS_TIMESTAMPS);
    private static String encodeCorrections(List<com.sankalpa.domain.lifecycle.BeginCorrection> corrections) {
        try { return AUDIT_JSON.writeValueAsString(corrections); }
        catch (com.fasterxml.jackson.core.JsonProcessingException failure) { throw new IllegalStateException("Invalid correction audit", failure); }
    }
    private static List<com.sankalpa.domain.lifecycle.BeginCorrection> decodeCorrections(ResultSet rs) throws SQLException {
        String value;
        try { value = rs.getString("begin_corrections_json"); }
        catch (SQLException absentLegacyColumn) { return List.of(); }
        try { return AUDIT_JSON.readValue(value, AUDIT_JSON.getTypeFactory().constructCollectionType(List.class, com.sankalpa.domain.lifecycle.BeginCorrection.class)); }
        catch (com.fasterxml.jackson.core.JsonProcessingException failure) { throw new SQLException("Invalid Begin correction audit", failure); }
    }

    public JdbcSankalpaPersistenceAdapter(JdbcTemplate jdbc) {
        this.jdbc = jdbc;
    }

    @Override
    public Optional<Sankalpa> findById(SankalpaId id) {
        List<LifecycleTransition> transitions = loadTransitions(id.toString());
        List<Sankalpa> results = jdbc.query("SELECT * FROM sankalpa WHERE id = ?",
                (rs, rowNum) -> mapSankalpa(rs, transitions), id.toString());
        return results.stream().findFirst();
    }

    @Override
    public Optional<Sankalpa> findByIdForUpdate(SankalpaId id) {
        int matched = jdbc.update("UPDATE sankalpa SET version = version WHERE id = ?", id.toString());
        return matched == 0 ? Optional.empty() : findById(id);
    }

    @Override
    public List<Sankalpa> findAll() {
        Map<String, List<LifecycleTransition>> transitionsBySankalpa = new HashMap<>();
        jdbc.query("""
                SELECT * FROM sankalpa_lifecycle_transition
                ORDER BY sankalpa_id, sequence_number
                """, (RowCallbackHandler) rs -> transitionsBySankalpa
                .computeIfAbsent(rs.getString("sankalpa_id"), ignored -> new ArrayList<>())
                .add(mapTransition(rs)));
        return jdbc.query("SELECT * FROM sankalpa ORDER BY declared_at DESC",
                (rs, rowNum) -> mapSankalpa(rs,
                        transitionsBySankalpa.getOrDefault(rs.getString("id"), List.of())));
    }

    @Override
    public void save(Sankalpa sankalpa) {
        Integer count = jdbc.queryForObject("SELECT COUNT(*) FROM sankalpa WHERE id = ?", Integer.class,
                sankalpa.id().toString());
        if (count != null && count > 0) update(sankalpa); else {
            try { insert(sankalpa); } catch (DuplicateKeyException failure) {
                if (sankalpa.extensionOf().isPresent()) throw new com.sankalpa.application.ExtensionClaimConflict(failure);
                throw failure;
            }
        }
        appendTransitions(sankalpa);
    }

    @Override public void saveBeginCorrection(Sankalpa corrected, LifecycleTransition expected) {
        var stored = findById(corrected.id()).orElseThrow();
        if (stored.version() != corrected.version() || stored.lifecycle().transitions().size() != 1
                || !stored.lifecycle().transitions().getFirst().equals(expected) || !expected.beginCorrections().isEmpty())
            throw new ConcurrentModificationException("Begin changed during correction");
        var transition = corrected.lifecycle().transitions().getFirst();
        int changed = jdbc.update("UPDATE sankalpa_lifecycle_transition SET effective_at=?, begin_corrections_json=? WHERE sankalpa_id=? AND sequence_number=0 AND effective_at=?",
                format(transition.effectiveAt()), encodeCorrections(transition.beginCorrections()), corrected.id().toString(), format(expected.effectiveAt()));
        if (changed != 1) throw new ConcurrentModificationException("Begin changed during correction");
        save(corrected);
    }

    @Override
    public void saveNew(Sankalpa sankalpa) {
        try { insert(sankalpa); }
        catch (DuplicateKeyException failure) {
            if (sankalpa.extensionOf().isPresent()) throw new com.sankalpa.application.ExtensionClaimConflict(failure);
            throw failure;
        }
        appendTransitions(sankalpa);
    }

    @Override
    public List<Sankalpa> findSeriesMembers(SankalpaId root) {
        Map<String, List<LifecycleTransition>> histories = new HashMap<>();
        jdbc.query("""
                SELECT t.* FROM sankalpa_lifecycle_transition t
                JOIN sankalpa s ON s.id = t.sankalpa_id
                WHERE s.series_id = ? ORDER BY t.sankalpa_id, t.sequence_number
                """, (RowCallbackHandler) rs -> histories.computeIfAbsent(rs.getString("sankalpa_id"),
                        ignored -> new ArrayList<>()).add(mapTransition(rs)), root.toString());
        return jdbc.query("SELECT * FROM sankalpa WHERE series_id = ? ORDER BY period_count, id",
                (rs, rowNum) -> mapSankalpa(rs, histories.getOrDefault(rs.getString("id"), List.of())), root.toString());
    }

    @Override
    public Optional<Sankalpa> findDirectExtension(SankalpaId source) {
        return jdbc.query("SELECT id FROM sankalpa WHERE extension_of = ?", (rs, rowNum) -> rs.getString(1),
                source.toString()).stream().findFirst().flatMap(id -> findById(SankalpaId.parse(id)));
    }

    private void insert(Sankalpa s) {
        jdbc.update("""
                INSERT INTO sankalpa
                  (id, title, description, action_type, start_date, period_unit,
                   times_per_period, period_count, current_state, declared_at, version, series_id, extension_of)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, s.id().toString(), s.title().value(), s.description().value(), s.actionType().name(),
                s.commitment().startDate().toString(), s.commitment().periodUnit().name(),
                s.commitment().timesPerPeriod(), s.commitment().periodCount(),
                s.lifecycle().current().name(), format(s.declaredAt()), s.version(), s.seriesId().toString(), s.extensionOf().map(Object::toString).orElse(null));
    }

    private void update(Sankalpa s) {
        int updated = jdbc.update("""
                UPDATE sankalpa SET title = ?, description = ?, action_type = ?, start_date = ?,
                    period_unit = ?, times_per_period = ?, period_count = ?, current_state = ?,
                    declared_at = ?, version = version + 1
                WHERE id = ? AND version = ?
                """, s.title().value(), s.description().value(), s.actionType().name(),
                s.commitment().startDate().toString(), s.commitment().periodUnit().name(),
                s.commitment().timesPerPeriod(), s.commitment().periodCount(),
                s.lifecycle().current().name(), format(s.declaredAt()), s.id().toString(), s.version());
        if (updated != 1) {
            throw new ConcurrentModificationException("Sankalpa was changed by another request");
        }
        s.markPersistedAtVersion(s.version() + 1);
    }

    private void appendTransitions(Sankalpa s) {
        List<LifecycleTransition> stored = loadTransitions(s.id().toString());
        List<LifecycleTransition> current = s.lifecycle().transitions();
        if (stored.size() > current.size() || !current.subList(0, stored.size()).equals(stored)) {
            throw new ConcurrentModificationException("Stored lifecycle audit does not match the aggregate history");
        }
        for (int sequence = stored.size(); sequence < current.size(); sequence++) {
            LifecycleTransition transition = current.get(sequence);
            jdbc.update("""
                    INSERT INTO sankalpa_lifecycle_transition
                      (sankalpa_id, sequence_number, from_state, to_state, effective_at, recorded_at, origin_sankalpa_id)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """, s.id().toString(), sequence, transition.from().name(), transition.to().name(),
                    format(transition.effectiveAt()), format(transition.recordedAt()), transition.originSankalpaId().toString());
            if (!transition.beginCorrections().isEmpty()) {
                jdbc.update("UPDATE sankalpa_lifecycle_transition SET begin_corrections_json=? WHERE sankalpa_id=? AND sequence_number=?",
                        encodeCorrections(transition.beginCorrections()), s.id().toString(), sequence);
            }
        }
    }

    private List<LifecycleTransition> loadTransitions(String id) {
        return jdbc.query("""
                SELECT * FROM sankalpa_lifecycle_transition
                WHERE sankalpa_id = ? ORDER BY sequence_number
                """, (rs, rowNum) -> mapTransition(rs), id);
    }

    private LifecycleTransition mapTransition(ResultSet rs) throws SQLException {
        return new LifecycleTransition(
                LifecycleState.valueOf(rs.getString("from_state")),
                LifecycleState.valueOf(rs.getString("to_state")),
                parse(rs.getString("effective_at")),
                parse(rs.getString("recorded_at")), SankalpaId.parse(rs.getString("origin_sankalpa_id")), decodeCorrections(rs));
    }

    private Sankalpa mapSankalpa(ResultSet rs, List<LifecycleTransition> transitions) throws SQLException {
        String id = rs.getString("id");
        LifecycleState current = LifecycleState.valueOf(rs.getString("current_state"));
        int storedPeriodCount = rs.getInt("period_count");
        Integer periodCount = rs.wasNull() ? null : storedPeriodCount;
        return Sankalpa.reconstitute(
                SankalpaId.parse(id),
                new Title(rs.getString("title")),
                new Description(rs.getString("description")),
                ActionType.valueOf(rs.getString("action_type")),
                new Commitment(LocalDate.parse(rs.getString("start_date")),
                        PeriodUnit.valueOf(rs.getString("period_unit")),
                        rs.getInt("times_per_period"), periodCount),
                parse(rs.getString("declared_at")),
                new LifecycleTimeline(current, transitions),
                rs.getInt("version"), SankalpaId.parse(rs.getString("series_id")),
                rs.getString("extension_of") == null ? null : SankalpaId.parse(rs.getString("extension_of")));
    }

    @Override
    public Optional<SessionIdentity> findIdentity(SessionId id) {
        return jdbc.query("SELECT * FROM session_identity WHERE session_id = ?",
                (rs, rowNum) -> new SessionIdentity(
                        SessionId.parse(rs.getString("session_id")),
                        SankalpaId.parse(rs.getString("sankalpa_id")),
                        SessionIdentityState.valueOf(rs.getString("identity_state"))),
                id.toString()).stream().findFirst();
    }

    @Override
    public void claimIdentity(SessionIdentity identity) {
        try {
            jdbc.update("""
                    INSERT INTO session_identity (session_id, sankalpa_id, identity_state)
                    VALUES (?, ?, ?)
                    """, identity.sessionId().toString(), identity.sankalpaId().toString(),
                    identity.state().name());
        } catch (DuplicateKeyException conflict) {
            throw new SessionIdentityClaimConflictException(conflict);
        }
    }

    @Override
    public void markDeleted(SessionId id) {
        int updated = jdbc.update("""
                UPDATE session_identity SET identity_state = 'DELETED'
                WHERE session_id = ? AND identity_state = 'ACTIVE'
                """, id.toString());
        if (updated != 1) {
            throw new IllegalStateException("Expected one ACTIVE session identity for " + id);
        }
    }

    @Override
    public Optional<Session> findById(SessionId id) {
        return jdbc.query("SELECT * FROM practice_session WHERE id = ?",
                (rs, rowNum) -> mapSession(rs), id.toString()).stream().findFirst();
    }

    @Override
    public void save(Session session) {
        jdbc.update("""
                INSERT INTO practice_session (id, sankalpa_id, occurred_at, logged_at)
                VALUES (?, ?, ?, ?)
                """, session.id().toString(), session.sankalpaId().toString(),
                format(session.occurredAt()), format(session.loggedAt()));
    }

    @Override
    public void delete(SessionId id) {
        int deleted = jdbc.update("DELETE FROM practice_session WHERE id = ?", id.toString());
        if (deleted != 1) {
            throw new IllegalStateException("ACTIVE session identity has no session fact: " + id);
        }
    }

    @Override
    public List<Session> findForSankalpa(SankalpaId id, LocalDate from, LocalDate until) {
        return jdbc.query("""
                SELECT * FROM practice_session
                WHERE sankalpa_id = ? AND occurred_at >= ? AND occurred_at <= ?
                ORDER BY occurred_at, id
                """, (rs, rowNum) -> mapSession(rs), id.toString(),
                format(from.atStartOfDay()), format(until.atTime(LocalTime.MAX)));
    }

    @Override
    public List<Session> findPageForSankalpa(SankalpaId id, LocalDate from, LocalDate until,
                                              long offset, int limit) {
        if (from == null) {
            return jdbc.query("""
                    SELECT * FROM practice_session WHERE sankalpa_id = ?
                    ORDER BY occurred_at DESC, id DESC LIMIT ? OFFSET ?
                    """, (rs, rowNum) -> mapSession(rs), id.toString(), limit, offset);
        }
        return jdbc.query("""
                SELECT * FROM practice_session
                WHERE sankalpa_id = ? AND occurred_at >= ? AND occurred_at <= ?
                ORDER BY occurred_at DESC, id DESC LIMIT ? OFFSET ?
                """, (rs, rowNum) -> mapSession(rs), id.toString(),
                format(from.atStartOfDay()), format(until.atTime(LocalTime.MAX)), limit, offset);
    }

    @Override
    public long countForSankalpa(SankalpaId id, LocalDate from, LocalDate until) {
        Long total;
        if (from == null) {
            total = jdbc.queryForObject("SELECT COUNT(*) FROM practice_session WHERE sankalpa_id = ?",
                    Long.class, id.toString());
        } else {
            total = jdbc.queryForObject("""
                    SELECT COUNT(*) FROM practice_session
                    WHERE sankalpa_id = ? AND occurred_at >= ? AND occurred_at <= ?
                    """, Long.class, id.toString(),
                    format(from.atStartOfDay()), format(until.atTime(LocalTime.MAX)));
        }
        return total == null ? 0 : total;
    }

    @Override public long readRevision() {
        String value = jdbc.queryForObject("SELECT metadata_value FROM service_metadata WHERE metadata_key='practice_revision'", String.class);
        long revision = Long.parseLong(value);
        if (revision < 0) throw new IllegalStateException("Invalid practice revision");
        return revision;
    }
    @Override public void incrementRevision() {
        jdbc.update("UPDATE service_metadata SET metadata_value=metadata_value WHERE metadata_key='practice_revision'");
        long next = Math.addExact(readRevision(), 1);
        jdbc.update("UPDATE service_metadata SET metadata_value=? WHERE metadata_key='practice_revision'", Long.toString(next));
    }
    @Override public List<Session> scanCandidates(List<SankalpaId> owners, LocalDate from, LocalDate until,
            com.sankalpa.application.SessionBoundary after, int limit) {
        if (owners.isEmpty()) return List.of();
        String sql = "SELECT p.* FROM practice_session p WHERE p.sankalpa_id IN ("
                + String.join(",", java.util.Collections.nCopies(owners.size(), "?")) + ")";
        List<Object> args = new ArrayList<>(owners.stream().map(Object::toString).toList());
        if (from != null) {
            sql += " AND p.occurred_at >= ? AND p.occurred_at <= ?";
            args.add(format(from.atStartOfDay())); args.add(format(until.atTime(LocalTime.MAX)));
        }
        if (after != null) {
            sql += " AND (p.occurred_at < ? OR (p.occurred_at = ? AND p.id < ?))";
            args.add(format(after.occurredAt())); args.add(format(after.occurredAt())); args.add(after.id().toString());
        }
        sql += " ORDER BY p.occurred_at DESC, p.id DESC LIMIT ?"; args.add(limit);
        return jdbc.query(sql, (rs,n) -> mapSession(rs), args.toArray());
    }

    private Session mapSession(ResultSet rs) throws SQLException {
        return new Session(SessionId.parse(rs.getString("id")),
                SankalpaId.parse(rs.getString("sankalpa_id")),
                parse(rs.getString("occurred_at")), parse(rs.getString("logged_at")));
    }

    private static String format(LocalDateTime value) { return LinkedSchemaMigration.TIMESTAMP.format(value); }
    private static LocalDateTime parse(String value) { return LocalDateTime.parse(value); }
}
