package com.sankalpa.adapter.out.persistence;

import com.sankalpa.application.ConcurrentModificationException;
import com.sankalpa.application.port.SankalpaRepository;
import com.sankalpa.application.port.SessionRepository;
import com.sankalpa.domain.*;
import com.sankalpa.domain.commitment.Commitment;
import com.sankalpa.domain.commitment.PeriodUnit;
import com.sankalpa.domain.lifecycle.LifecycleState;
import com.sankalpa.domain.lifecycle.LifecycleTimeline;
import com.sankalpa.domain.lifecycle.LifecycleTransition;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Repository;

import java.sql.ResultSet;
import java.sql.SQLException;
import java.time.LocalDate;
import java.time.LocalDateTime;
import java.time.LocalTime;
import java.util.List;
import java.util.Optional;

@Repository
public class JdbcSankalpaPersistenceAdapter implements SankalpaRepository, SessionRepository {
    private final JdbcTemplate jdbc;

    public JdbcSankalpaPersistenceAdapter(JdbcTemplate jdbc) {
        this.jdbc = jdbc;
    }

    @Override
    public Optional<Sankalpa> findById(SankalpaId id) {
        List<Sankalpa> results = jdbc.query("SELECT * FROM sankalpa WHERE id = ?",
                (rs, rowNum) -> mapSankalpa(rs), id.toString());
        return results.stream().findFirst();
    }

    @Override
    public List<Sankalpa> findAll() {
        List<String> ids = jdbc.query("SELECT id FROM sankalpa ORDER BY declared_at DESC",
                (rs, rowNum) -> rs.getString(1));
        return ids.stream().map(id -> findById(SankalpaId.parse(id)).orElseThrow()).toList();
    }

    @Override
    public void save(Sankalpa sankalpa) {
        Integer count = jdbc.queryForObject("SELECT COUNT(*) FROM sankalpa WHERE id = ?", Integer.class,
                sankalpa.id().toString());
        if (count != null && count > 0) update(sankalpa); else insert(sankalpa);
        synchronizeTransitions(sankalpa);
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

    private void synchronizeTransitions(Sankalpa s) {
        jdbc.update("DELETE FROM sankalpa_lifecycle_transition WHERE sankalpa_id = ?", s.id().toString());
        int sequence = 0;
        for (LifecycleTransition transition : s.lifecycle().transitions()) {
            jdbc.update("""
                    INSERT INTO sankalpa_lifecycle_transition
                      (sankalpa_id, sequence_number, from_state, to_state, effective_at, recorded_at)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """, s.id().toString(), sequence++, transition.from().name(), transition.to().name(),
                    format(transition.effectiveAt()), format(transition.recordedAt()));
        }
    }

    private Sankalpa mapSankalpa(ResultSet rs) throws SQLException {
        String id = rs.getString("id");
        List<LifecycleTransition> transitions = jdbc.query("""
                SELECT * FROM sankalpa_lifecycle_transition
                WHERE sankalpa_id = ? ORDER BY sequence_number
                """, (transitionRs, rowNum) -> new LifecycleTransition(
                LifecycleState.valueOf(transitionRs.getString("from_state")),
                LifecycleState.valueOf(transitionRs.getString("to_state")),
                parse(transitionRs.getString("effective_at")),
                parse(transitionRs.getString("recorded_at"))), id);
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
    public void save(Session session) {
        jdbc.update("""
                INSERT INTO practice_session (id, sankalpa_id, occurred_at, logged_at)
                VALUES (?, ?, ?, ?)
                """, session.id().toString(), session.sankalpaId().toString(),
                format(session.occurredAt()), format(session.loggedAt()));
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
