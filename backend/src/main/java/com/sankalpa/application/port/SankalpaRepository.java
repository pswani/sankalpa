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
    /** Insert-only identity claim; a racing create must never update an existing vow. */
    default void saveNew(Sankalpa sankalpa) { save(sankalpa); }
    default List<Sankalpa> findSeriesMembers(SankalpaId root) {
        return findAll().stream().filter(s -> s.seriesId().equals(root)).toList();
    }
    default Optional<Sankalpa> findDirectExtension(SankalpaId source) {
        return findAll().stream().filter(s -> s.extensionOf().filter(source::equals).isPresent()).findFirst();
    }
    default void acquireSeriesWriteGuard(SankalpaId root) { findByIdForUpdate(root).orElseThrow(); }
    default long readRevision() { return 0; }
    default void incrementRevision() {}
}
