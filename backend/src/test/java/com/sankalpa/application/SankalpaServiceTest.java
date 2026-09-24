package com.sankalpa.application;

import com.sankalpa.application.port.SankalpaClock;
import com.sankalpa.application.port.SankalpaRepository;
import com.sankalpa.application.port.SessionRepository;
import com.sankalpa.domain.*;
import com.sankalpa.domain.commitment.PeriodUnit;
import com.sankalpa.domain.commitment.PeriodStanding;
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

        SessionId id = SessionId.newId();
        Session logged = service.logSession(result.id(), id, occurredAt).session();

        assertThat(logged.id()).isEqualTo(id);
        assertThat(logged.occurredAt()).isEqualTo(occurredAt);
        assertThat(logged.loggedAt()).isEqualTo(clock.now());
        assertThat(sessions.saved).containsExactly(logged);
        assertThat(sankalpas.forUpdateReads).isEqualTo(1);
    }

    @Test
    void exactReplayReturnsOriginalWithoutRecheckingChangedLifecycle() {
        Sankalpa result = declare(PeriodUnit.DAY);
        service.begin(result.id(), LocalDateTime.of(2026, 6, 1, 0, 0));
        SessionId id = SessionId.newId();
        LocalDateTime occurredAt = LocalDateTime.of(2026, 6, 10, 8, 0);
        Session first = service.logSession(result.id(), id, occurredAt).session();
        clock.now = clock.now.plusHours(1);
        service.pause(result.id());

        SessionLogResult replay = service.logSession(result.id(), id, occurredAt);

        assertThat(replay.created()).isFalse();
        assertThat(replay.session()).isEqualTo(first);
        assertThat(sessions.saved).containsExactly(first);
    }

    @Test
    void identityReuseWithDifferentValuesConflictsButDifferentIdsAtSameTimeBothSucceed() {
        Sankalpa result = declare(PeriodUnit.DAY);
        service.begin(result.id(), LocalDateTime.of(2026, 6, 1, 0, 0));
        LocalDateTime occurredAt = LocalDateTime.of(2026, 6, 10, 8, 0);
        SessionId firstId = SessionId.newId();
        service.logSession(result.id(), firstId, occurredAt);

        assertThatThrownBy(() -> service.logSession(result.id(), firstId, occurredAt.plusMinutes(1)))
                .isInstanceOf(SessionIdentityConflictException.class);

        SessionLogResult second = service.logSession(result.id(), SessionId.newId(), occurredAt);
        assertThat(second.created()).isTrue();
        assertThat(sessions.saved).hasSize(2);
    }

    @Test
    void deleteIsIdempotentAndPreventsDelayedCreate() {
        Sankalpa result = declare(PeriodUnit.DAY);
        service.begin(result.id(), LocalDateTime.of(2026, 6, 1, 0, 0));
        SessionId id = SessionId.newId();

        service.deleteSession(result.id(), id);
        service.deleteSession(result.id(), id);

        assertThat(sessions.identities.get(id).state()).isEqualTo(SessionIdentityState.DELETED);
        assertThatThrownBy(() -> service.logSession(
                result.id(), id, LocalDateTime.of(2026, 6, 10, 8, 0)))
                .isInstanceOf(SessionDeletedException.class);
        assertThat(sessions.saved).isEmpty();
    }

    @Test
    void deletingActiveSessionRemovesItFromReads() {
        Sankalpa result = declare(PeriodUnit.DAY);
        service.begin(result.id(), LocalDateTime.of(2026, 6, 1, 0, 0));
        SessionId id = SessionId.newId();
        service.logSession(result.id(), id, LocalDateTime.of(2026, 6, 10, 8, 0));

        service.deleteSession(result.id(), id);

        assertThat(sessions.saved).isEmpty();
        assertThat(sessions.identities.get(id).state()).isEqualTo(SessionIdentityState.DELETED);
    }

    @Test
    void deletionRecalculatesClosedAndOpenPeriodOutcomes() {
        Sankalpa result = declare(PeriodUnit.DAY);
        service.begin(result.id(), LocalDateTime.of(2026, 6, 1, 0, 0));
        SessionId closedId = SessionId.newId();
        SessionId openId = SessionId.newId();
        service.logSession(result.id(), closedId, LocalDateTime.of(2026, 6, 10, 8, 0));
        service.logSession(result.id(), openId, LocalDateTime.of(2026, 6, 15, 8, 0));

        var closedBefore = service.periodOutcomes(
                result.id(), LocalDate.of(2026, 6, 10), LocalDate.of(2026, 6, 10)).getFirst();
        var openBefore = service.periodOutcomes(
                result.id(), LocalDate.of(2026, 6, 15), LocalDate.of(2026, 6, 15)).getFirst();
        assertThat(closedBefore.standing()).isEqualTo(PeriodStanding.SATISFIED);
        assertThat(openBefore.standing()).isEqualTo(PeriodStanding.OPEN);
        assertThat(openBefore.performed()).isEqualTo(1);

        service.deleteSession(result.id(), closedId);
        service.deleteSession(result.id(), openId);

        var closedAfter = service.periodOutcomes(
                result.id(), LocalDate.of(2026, 6, 10), LocalDate.of(2026, 6, 10)).getFirst();
        var openAfter = service.periodOutcomes(
                result.id(), LocalDate.of(2026, 6, 15), LocalDate.of(2026, 6, 15)).getFirst();
        assertThat(closedAfter.standing()).isEqualTo(PeriodStanding.UNSATISFIED);
        assertThat(closedAfter.missed()).isEqualTo(1);
        assertThat(openAfter.standing()).isEqualTo(PeriodStanding.OPEN);
        assertThat(openAfter.performed()).isZero();
        assertThat(openAfter.missed()).isZero();
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
        private final Map<SessionId, SessionIdentity> identities = new LinkedHashMap<>();
        private LocalDate lastFrom;
        private LocalDate lastUntil;
        private long lastOffset;
        private int lastLimit;
        private long total;

        @Override public Optional<SessionIdentity> findIdentity(SessionId id) {
            return Optional.ofNullable(identities.get(id));
        }
        @Override public void claimIdentity(SessionIdentity identity) {
            if (identities.putIfAbsent(identity.sessionId(), identity) != null) {
                throw new SessionIdentityClaimConflictException(null);
            }
        }
        @Override public void markDeleted(SessionId id) {
            SessionIdentity old = identities.get(id);
            identities.put(id, new SessionIdentity(id, old.sankalpaId(), SessionIdentityState.DELETED));
        }
        @Override public Optional<Session> findById(SessionId id) {
            return saved.stream().filter(session -> session.id().equals(id)).findFirst();
        }
        @Override public void save(Session session) { saved.add(session); }
        @Override public void delete(SessionId id) { saved.removeIf(session -> session.id().equals(id)); }
        @Override public List<Session> findForSankalpa(SankalpaId id, LocalDate from, LocalDate until) {
            lastFrom = from;
            lastUntil = until;
            return saved.stream().filter(session -> session.sankalpaId().equals(id))
                    .filter(session -> !session.occurredAt().toLocalDate().isBefore(from))
                    .filter(session -> !session.occurredAt().toLocalDate().isAfter(until))
                    .toList();
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
