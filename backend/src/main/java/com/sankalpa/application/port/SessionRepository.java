package com.sankalpa.application.port;

import com.sankalpa.application.SessionIdentity;
import com.sankalpa.domain.SankalpaId;
import com.sankalpa.domain.Session;
import com.sankalpa.domain.SessionId;

import java.time.LocalDate;
import java.util.List;
import java.util.Optional;

public interface SessionRepository {
    Optional<SessionIdentity> findIdentity(SessionId id);
    void claimIdentity(SessionIdentity identity);
    void markDeleted(SessionId id);
    Optional<Session> findById(SessionId id);
    void save(Session session);
    void delete(SessionId id);
    List<Session> findForSankalpa(SankalpaId id, LocalDate from, LocalDate until);
    List<Session> findPageForSankalpa(
            SankalpaId id, LocalDate from, LocalDate until, long offset, int limit);
    long countForSankalpa(SankalpaId id, LocalDate from, LocalDate until);
    default List<Session> scanCandidates(List<SankalpaId> owners, LocalDate from, LocalDate until,
            com.sankalpa.application.SessionBoundary after, int limit) {
        var comparator = java.util.Comparator.comparing(Session::occurredAt)
                .thenComparing(s -> s.id().toString()).reversed();
        return owners.stream().flatMap(id -> findForSankalpa(id,
                    from == null ? LocalDate.MIN : from, until == null ? LocalDate.MAX : until).stream())
                .filter(s -> after == null || s.occurredAt().isBefore(after.occurredAt())
                    || (s.occurredAt().equals(after.occurredAt()) && s.id().toString().compareTo(after.id().toString()) < 0))
                .sorted(comparator).limit(limit).toList();
    }
}
