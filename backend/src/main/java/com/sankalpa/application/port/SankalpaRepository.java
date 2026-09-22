package com.sankalpa.application.port;

import com.sankalpa.domain.Sankalpa;
import com.sankalpa.domain.SankalpaId;

import java.util.List;
import java.util.Optional;

public interface SankalpaRepository {
    Optional<Sankalpa> findById(SankalpaId id);
    /** Acquires the parent write lock used to serialize session logging with lifecycle commands. */
    Optional<Sankalpa> findByIdForUpdate(SankalpaId id);
    List<Sankalpa> findAll();
    void save(Sankalpa sankalpa);
}
