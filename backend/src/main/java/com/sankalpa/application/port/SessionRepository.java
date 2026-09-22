package com.sankalpa.application.port;

import com.sankalpa.domain.SankalpaId;
import com.sankalpa.domain.Session;

import java.time.LocalDate;
import java.util.List;

public interface SessionRepository {
    void save(Session session);
    List<Session> findForSankalpa(SankalpaId id, LocalDate from, LocalDate until);
    List<Session> findPageForSankalpa(
            SankalpaId id, LocalDate from, LocalDate until, long offset, int limit);
    long countForSankalpa(SankalpaId id, LocalDate from, LocalDate until);
}
