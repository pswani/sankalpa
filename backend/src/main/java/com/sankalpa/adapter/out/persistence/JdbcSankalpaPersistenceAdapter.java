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
public class JdbcSankalpaPersistenceAdapter implements SankalpaRepository, SessionRepository {
    private final JdbcTemplate jdbc;

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
        if (count != null && count > 0) update(sankalpa); else insert(sankalpa);
        appendTransitions(sankalpa);
    }

    private void insert(Sankalpa s) {
        jdbc.update("""
                INSERT INTO sankalpa
                  (id, title, description, action_type, start_date, period_unit,
                   times_per_period, period_count, current_state, declared_at, version)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, s.id().toString(), s.title().value(), s.description().value(), s.actionType().name(),
                s.commitment().startDate().toString(), s.commitment().periodUnit().name(),
                s.commitment().timesPerPeriod(), s.commitment().periodCount(),
                s.lifecycle().current().name(), format(s.declaredAt()), s.version());
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
                      (sankalpa_id, sequence_number, from_state, to_state, effective_at, recorded_at)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """, s.id().toString(), sequence, transition.from().name(), transition.to().name(),
                    format(transition.effectiveAt()), format(transition.recordedAt()));
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
                parse(rs.getString("recorded_at")));
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
                rs.getInt("version"));
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

    private Session mapSession(ResultSet rs) throws SQLException {
        return new Session(SessionId.parse(rs.getString("id")),
                SankalpaId.parse(rs.getString("sankalpa_id")),
                parse(rs.getString("occurred_at")), parse(rs.getString("logged_at")));
    }

    private static String format(LocalDateTime value) { return value.toString(); }
    private static LocalDateTime parse(String value) { return LocalDateTime.parse(value); }
}
