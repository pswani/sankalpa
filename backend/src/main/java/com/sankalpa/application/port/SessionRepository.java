package com.sankalpa.application.port;

import com.sankalpa.domain.SankalpaId;
import com.sankalpa.domain.Session;
import com.sankalpa.domain.SessionId;

import java.time.LocalDate;
import java.util.List;
import java.util.Optional;

public interface SessionRepository {
    Optional<Session> findById(SessionId id);
    Optional<SankalpaId> findDeletionOwner(SessionId id);
    void save(Session session);
    void delete(SessionId id);
    void recordDeletion(SessionId id, SankalpaId sankalpaId);
    List<Session> findForSankalpa(SankalpaId id, LocalDate from, LocalDate until);
    List<Session> findPageForSankalpa(
            SankalpaId id, LocalDate from, LocalDate until, long offset, int limit);
    long countForSankalpa(SankalpaId id, LocalDate from, LocalDate until);
}
