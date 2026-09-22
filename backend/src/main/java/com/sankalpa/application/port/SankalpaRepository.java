package com.sankalpa.application.port;

import com.sankalpa.domain.Sankalpa;
import com.sankalpa.domain.SankalpaId;

import java.util.List;
import java.util.Optional;

public interface SankalpaRepository {
    Optional<Sankalpa> findById(SankalpaId id);
    List<Sankalpa> findAll();
    void save(Sankalpa sankalpa);
}
