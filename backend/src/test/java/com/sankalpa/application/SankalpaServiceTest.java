package com.sankalpa.application;

import com.sankalpa.application.port.SankalpaClock;
import com.sankalpa.application.port.SankalpaRepository;
import com.sankalpa.application.port.SessionRepository;
import com.sankalpa.domain.*;
import com.sankalpa.domain.commitment.PeriodUnit;
import com.sankalpa.domain.lifecycle.CompletionOutcome;
import com.sankalpa.domain.lifecycle.LifecycleState;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

import java.time.LocalDate;
import java.time.LocalDateTime;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Optional;

import static org.assertj.core.api.Assertions.*;

class SankalpaServiceTest {
    private final FakeSankalpas sankalpas = new FakeSankalpas();
    private final FakeSessions sessions = new FakeSessions();
    private final MutableClock clock = new MutableClock(LocalDateTime.of(2026, 6, 15, 12, 0));
    private SankalpaService service;

    @BeforeEach
    void setUp() {
        service = new SankalpaService(sankalpas, sessions, clock);
    }

    @Test
    void declarationUsesClockAndSavesExactlyOnce() {
        Sankalpa result = declare(PeriodUnit.DAY);

        assertThat(result.declaredAt()).isEqualTo(clock.now());
        assertThat(result.lifecycle().current()).isEqualTo(LifecycleState.NOT_STARTED);
        assertThat(sankalpas.saveCount).isEqualTo(1);
        assertThat(sankalpas.findById(result.id())).containsSame(result);
    }

    @Test
    void retryingADeclarationIdReturnsTheOriginalWithoutSavingTwice() {
        SankalpaId id = SankalpaId.newId();
        Sankalpa first = service.declare(id, "Practice", "Daily", ActionType.MEDITATION,
                LocalDate.of(2026, 6, 1), PeriodUnit.DAY, 1, null);

        Sankalpa retried = service.declare(id, "Practice", "Daily", ActionType.MEDITATION,
                LocalDate.of(2026, 6, 1), PeriodUnit.DAY, 1, null);

        assertThat(retried).isSameAs(first);
        assertThat(sankalpas.saveCount).isEqualTo(1);
    }

    @Test
    void reusingADeclarationIdForDifferentValuesIsRefused() {
        SankalpaId id = SankalpaId.newId();
        service.declare(id, "Practice", "Daily", ActionType.MEDITATION,
                LocalDate.of(2026, 6, 1), PeriodUnit.DAY, 1, null);

        assertThatThrownBy(() -> service.declare(id, "Changed", "Daily", ActionType.MEDITATION,
                LocalDate.of(2026, 6, 1), PeriodUnit.DAY, 1, null))
                .isInstanceOf(DomainException.class)
                .extracting("code").isEqualTo("IDEMPOTENCY_CONFLICT");
        assertThat(sankalpas.saveCount).isEqualTo(1);
    }

    @Test
    void failedDomainCommandDoesNotSave() {
        Sankalpa result = declare(PeriodUnit.DAY);
        int savesBeforeFailure = sankalpas.saveCount;

        assertThatThrownBy(() -> service.resume(result.id()))
                .isInstanceOf(DomainException.class)
                .extracting("code").isEqualTo("INVALID_LIFECYCLE_TRANSITION");
        assertThat(sankalpas.saveCount).isEqualTo(savesBeforeFailure);

        assertThatThrownBy(() -> service.complete(result.id(), null))
                .isInstanceOf(DomainException.class)
                .extracting("code").isEqualTo("INVALID_COMPLETION_OUTCOME");
        assertThat(sankalpas.saveCount).isEqualTo(savesBeforeFailure);
    }

    @Test
    void nonBeginTransitionUsesServerClockForBothAuditTimes() {
        Sankalpa result = declare(PeriodUnit.DAY);
        service.begin(result.id(), LocalDateTime.of(2026, 6, 1, 8, 0));
        clock.now = LocalDateTime.of(2026, 6, 16, 9, 30);

        service.pause(result.id());

        var pause = result.lifecycle().transitions().getLast();
        assertThat(pause.effectiveAt()).isEqualTo(clock.now());
        assertThat(pause.recordedAt()).isEqualTo(clock.now());

        clock.now = LocalDateTime.of(2026, 6, 16, 10, 30);
        service.resume(result.id());
        var resume = result.lifecycle().transitions().getLast();
        assertThat(resume.effectiveAt()).isEqualTo(clock.now());
        assertThat(resume.recordedAt()).isEqualTo(clock.now());

        clock.now = LocalDateTime.of(2026, 6, 16, 11, 30);
        service.complete(result.id(), CompletionOutcome.SUCCESSFUL);
        var complete = result.lifecycle().transitions().getLast();
        assertThat(complete.effectiveAt()).isEqualTo(clock.now());
        assertThat(complete.recordedAt()).isEqualTo(clock.now());

        Sankalpa stoppable = declare(PeriodUnit.DAY);
        clock.now = LocalDateTime.of(2026, 6, 16, 12, 30);
        service.stop(stoppable.id());
        var stop = stoppable.lifecycle().transitions().getLast();
        assertThat(stop.effectiveAt()).isEqualTo(clock.now());
        assertThat(stop.recordedAt()).isEqualTo(clock.now());
    }

    @Test
    void periodQueryExpandsSessionReadToWholeSelectedWindow() {
        Sankalpa result = declare(PeriodUnit.WEEK);

        service.periodOutcomes(result.id(), LocalDate.of(2026, 6, 1), LocalDate.of(2026, 6, 1));

        assertThat(sessions.lastFrom).isEqualTo(LocalDate.of(2026, 6, 1));
        assertThat(sessions.lastUntil).isEqualTo(LocalDate.of(2026, 6, 7));
    }

    @Test
    void sessionQueryCalculatesBoundedPaginationMetadataAndOffset() {
        Sankalpa result = declare(PeriodUnit.DAY);
        sessions.total = 25;

        PageResult<Session> page = service.sessions(result.id(), null, null, 2, 10);

        assertThat(page.page()).isEqualTo(2);
        assertThat(page.size()).isEqualTo(10);
        assertThat(page.totalElements()).isEqualTo(25);
        assertThat(page.totalPages()).isEqualTo(3);
        assertThat(sessions.lastOffset).isEqualTo(20);
        assertThat(sessions.lastLimit).isEqualTo(10);
    }

    @Test
    void logSessionUsesClockAndPersistsOnlyAfterDomainAcceptance() {
        Sankalpa result = declare(PeriodUnit.DAY);
        service.begin(result.id(), LocalDateTime.of(2026, 6, 1, 0, 0));
        LocalDateTime occurredAt = LocalDateTime.of(2026, 6, 10, 8, 0);

        Session logged = service.logSession(result.id(), occurredAt);

        assertThat(logged.occurredAt()).isEqualTo(occurredAt);
        assertThat(logged.loggedAt()).isEqualTo(clock.now());
        assertThat(sessions.saved).containsExactly(logged);
        assertThat(sankalpas.forUpdateReads).isEqualTo(1);
    }

    @Test
    void retryingASessionIdReturnsTheOriginalWithoutSavingTwice() {
        Sankalpa result = declare(PeriodUnit.DAY);
        service.begin(result.id(), LocalDateTime.of(2026, 6, 1, 0, 0));
        SessionId sessionId = SessionId.newId();
        LocalDateTime occurredAt = LocalDateTime.of(2026, 6, 10, 8, 0);

        Session first = service.logSession(result.id(), sessionId, occurredAt);
        service.pause(result.id());
        Session retried = service.logSession(result.id(), sessionId, occurredAt);

        assertThat(retried).isSameAs(first);
        assertThat(sessions.saved).containsExactly(first);
        assertThat(service.logSessionResult(result.id(), sessionId, occurredAt).created()).isFalse();
    }

    @Test
    void reusingASessionIdForADifferentMomentIsRefused() {
        Sankalpa result = declare(PeriodUnit.DAY);
        service.begin(result.id(), LocalDateTime.of(2026, 6, 1, 0, 0));
        SessionId sessionId = SessionId.newId();
        LocalDateTime occurredAt = LocalDateTime.of(2026, 6, 10, 8, 0);
        service.logSession(result.id(), sessionId, occurredAt);

        assertThatThrownBy(() -> service.logSession(
                result.id(), sessionId, occurredAt.plusMinutes(1)))
                .isInstanceOf(DomainException.class)
                .extracting("code").isEqualTo("SESSION_IDENTITY_CONFLICT");
        assertThat(sessions.saved).hasSize(1);
    }

    @Test
    void separatelyIdentifiedSessionsAtTheSameMomentRemainSeparate() {
        Sankalpa result = declare(PeriodUnit.DAY);
        service.begin(result.id(), LocalDateTime.of(2026, 6, 1, 0, 0));
        LocalDateTime occurredAt = LocalDateTime.of(2026, 6, 10, 8, 0);

        Session first = service.logSession(result.id(), SessionId.newId(), occurredAt);
        Session second = service.logSession(result.id(), SessionId.newId(), occurredAt);

        assertThat(first.id()).isNotEqualTo(second.id());
        assertThat(sessions.saved).containsExactly(first, second);
    }

    @Test
    void deletingAStoredSessionRemovesItAndLeavesATombstone() {
        Sankalpa result = declare(PeriodUnit.DAY);
        service.begin(result.id(), LocalDateTime.of(2026, 6, 1, 0, 0));
        SessionId sessionId = SessionId.newId();
        LocalDateTime occurredAt = LocalDateTime.of(2026, 6, 10, 8, 0);
        service.logSession(result.id(), sessionId, occurredAt);

        service.deleteSession(result.id(), sessionId);
        service.deleteSession(result.id(), sessionId);

        assertThat(sessions.findById(sessionId)).isEmpty();
        assertThat(sessions.findDeletionOwner(sessionId)).contains(result.id());
        assertThatThrownBy(() -> service.logSession(result.id(), sessionId, occurredAt))
                .isInstanceOf(DomainException.class)
                .extracting("code").isEqualTo("SESSION_DELETED");
    }

    @Test
    void deletingAnUnknownSessionPreventsADelayedCreate() {
        Sankalpa result = declare(PeriodUnit.DAY);
        service.begin(result.id(), LocalDateTime.of(2026, 6, 1, 0, 0));
        SessionId sessionId = SessionId.newId();

        service.deleteSession(result.id(), sessionId);

        assertThatThrownBy(() -> service.logSession(
                result.id(), sessionId, LocalDateTime.of(2026, 6, 10, 8, 0)))
                .isInstanceOf(DomainException.class)
                .extracting("code").isEqualTo("SESSION_DELETED");
    }

    private Sankalpa declare(PeriodUnit unit) {
        return service.declare("Practice", "Daily", ActionType.MEDITATION,
                LocalDate.of(2026, 6, 1), unit, 1, null);
    }

    private static final class FakeSankalpas implements SankalpaRepository {
        private final Map<SankalpaId, Sankalpa> values = new LinkedHashMap<>();
        private int saveCount;
        private int forUpdateReads;

        @Override public Optional<Sankalpa> findById(SankalpaId id) { return Optional.ofNullable(values.get(id)); }
        @Override public Optional<Sankalpa> findByIdForUpdate(SankalpaId id) {
            forUpdateReads++;
            return findById(id);
        }
        @Override public List<Sankalpa> findAll() { return List.copyOf(values.values()); }
        @Override public void save(Sankalpa sankalpa) {
            values.put(sankalpa.id(), sankalpa);
            saveCount++;
        }
    }

    private static final class FakeSessions implements SessionRepository {
        private final java.util.ArrayList<Session> saved = new java.util.ArrayList<>();
        private LocalDate lastFrom;
        private LocalDate lastUntil;
        private long lastOffset;
        private int lastLimit;
        private long total;
        private final Map<SessionId, SankalpaId> deletions = new LinkedHashMap<>();

        @Override public void save(Session session) { saved.add(session); }
        @Override public Optional<Session> findById(SessionId id) {
            return saved.stream().filter(session -> session.id().equals(id)).findFirst();
        }
        @Override public Optional<SankalpaId> findDeletionOwner(SessionId id) {
            return Optional.ofNullable(deletions.get(id));
        }
        @Override public void delete(SessionId id) {
            saved.removeIf(session -> session.id().equals(id));
        }
        @Override public void recordDeletion(SessionId id, SankalpaId sankalpaId) {
            deletions.put(id, sankalpaId);
        }
        @Override public List<Session> findForSankalpa(SankalpaId id, LocalDate from, LocalDate until) {
            lastFrom = from;
            lastUntil = until;
            return List.of();
        }
        @Override public List<Session> findPageForSankalpa(
                SankalpaId id, LocalDate from, LocalDate until, long offset, int limit) {
            lastFrom = from;
            lastUntil = until;
            lastOffset = offset;
            lastLimit = limit;
            return List.of();
        }
        @Override public long countForSankalpa(SankalpaId id, LocalDate from, LocalDate until) {
            return total;
        }
    }

    private static final class MutableClock implements SankalpaClock {
        private LocalDateTime now;
        private MutableClock(LocalDateTime now) { this.now = now; }
        @Override public LocalDateTime now() { return now; }
        @Override public LocalDate today() { return now.toLocalDate(); }
    }
}
