package com.sankalpa.adapter;

import com.sankalpa.adapter.out.persistence.JdbcSankalpaPersistenceAdapter;
import com.sankalpa.application.SankalpaUseCases;
import com.sankalpa.application.SessionDeletedException;
import com.sankalpa.application.SessionLogResult;
import com.sankalpa.application.port.SankalpaClock;
import com.sankalpa.domain.ActionType;
import com.sankalpa.domain.DomainException;
import com.sankalpa.domain.Sankalpa;
import com.sankalpa.domain.SessionId;
import com.sankalpa.domain.commitment.PeriodUnit;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.test.context.ActiveProfiles;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.support.TransactionTemplate;

import java.time.LocalDateTime;
import java.util.concurrent.*;
import java.util.List;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

@SpringBootTest(properties = "spring.datasource.hikari.maximum-pool-size=2")
@ActiveProfiles("test")
class ConcurrentCommandIntegrationTest {
    @Autowired SankalpaUseCases useCases;
    @Autowired SankalpaClock clock;
    @Autowired JdbcSankalpaPersistenceAdapter adapter;
    @Autowired PlatformTransactionManager transactionManager;
    @Autowired JdbcTemplate jdbc;

    private final ExecutorService executor = Executors.newFixedThreadPool(2);

    @BeforeEach
    void clean() {
        jdbc.update("DELETE FROM practice_session");
        jdbc.update("DELETE FROM session_identity");
        jdbc.update("DELETE FROM sankalpa_lifecycle_transition");
        jdbc.update("DELETE FROM sankalpa");
    }

    @AfterEach
    void stopExecutor() {
        executor.shutdownNow();
    }

    @Test
    void sessionWaitsForUncommittedPauseAndCannotCommitAgainstStaleLifecycle() throws Exception {
        Sankalpa declared = useCases.declare("Walk", "", ActionType.PHYSICAL_ACTIVITY,
                clock.today(), PeriodUnit.DAY, 1, null);
        useCases.begin(declared.id(), clock.today().atStartOfDay());
        LocalDateTime pauseAt = clock.now().minusSeconds(2);
        LocalDateTime sessionAt = pauseAt.plusSeconds(1);
        CountDownLatch pauseWritten = new CountDownLatch(1);
        CountDownLatch releasePause = new CountDownLatch(1);
        CountDownLatch sessionStarted = new CountDownLatch(1);

        Future<?> pause = executor.submit(() -> new TransactionTemplate(transactionManager)
                .executeWithoutResult(status -> {
                    Sankalpa sankalpa = adapter.findById(declared.id()).orElseThrow();
                    sankalpa.pause(pauseAt);
                    adapter.save(sankalpa);
                    pauseWritten.countDown();
                    await(releasePause);
                }));
        assertThat(pauseWritten.await(5, TimeUnit.SECONDS)).isTrue();

        Future<?> sessionAttempt = executor.submit(() -> {
            sessionStarted.countDown();
            return useCases.logSession(declared.id(), SessionId.newId(), sessionAt);
        });
        assertThat(sessionStarted.await(5, TimeUnit.SECONDS)).isTrue();
        Thread.sleep(100);
        assertThat(sessionAttempt.isDone()).isFalse();

        releasePause.countDown();
        pause.get(5, TimeUnit.SECONDS);
        assertThatThrownBy(() -> sessionAttempt.get(5, TimeUnit.SECONDS))
                .isInstanceOf(ExecutionException.class)
                .hasCauseInstanceOf(DomainException.class)
                .satisfies(error -> assertThat(((DomainException) error.getCause()).code())
                        .isEqualTo("SANKALPA_NOT_IN_PROGRESS"));
        assertThat(adapter.countForSankalpa(declared.id(), null, null)).isZero();
    }

    @Test
    void concurrentExactCreatesProduceOneFactAndOneReplay() throws Exception {
        Sankalpa declared = runningSankalpa();
        SessionId sessionId = SessionId.newId();
        LocalDateTime occurredAt = clock.now().minusMinutes(1);
        CyclicBarrier start = new CyclicBarrier(2);

        Callable<SessionLogResult> command = () -> {
            start.await(5, TimeUnit.SECONDS);
            return useCases.logSession(declared.id(), sessionId, occurredAt);
        };
        Future<SessionLogResult> first = executor.submit(command);
        Future<SessionLogResult> second = executor.submit(command);

        List<SessionLogResult> results = List.of(
                first.get(5, TimeUnit.SECONDS), second.get(5, TimeUnit.SECONDS));
        assertThat(results).extracting(SessionLogResult::created)
                .containsExactlyInAnyOrder(true, false);
        assertThat(results).extracting(result -> result.session().id())
                .containsOnly(sessionId);
        assertThat(adapter.countForSankalpa(declared.id(), null, null)).isEqualTo(1);
        assertThat(jdbc.queryForObject(
                "SELECT COUNT(*) FROM session_identity WHERE session_id = ? AND identity_state = 'ACTIVE'",
                Integer.class, sessionId.toString())).isEqualTo(1);
    }

    @Test
    void concurrentCreateAndDeleteAlwaysEndDeletedWithoutResurrection() throws Exception {
        Sankalpa declared = runningSankalpa();
        SessionId sessionId = SessionId.newId();
        LocalDateTime occurredAt = clock.now().minusMinutes(1);
        CyclicBarrier start = new CyclicBarrier(2);

        Future<?> create = executor.submit(() -> {
            await(start);
            try {
                useCases.logSession(declared.id(), sessionId, occurredAt);
            } catch (SessionDeletedException expected) {
                // Delete won before create claimed the identity.
            }
        });
        Future<?> delete = executor.submit(() -> {
            await(start);
            useCases.deleteSession(declared.id(), sessionId);
        });

        create.get(5, TimeUnit.SECONDS);
        delete.get(5, TimeUnit.SECONDS);
        assertThat(adapter.countForSankalpa(declared.id(), null, null)).isZero();
        assertThat(jdbc.queryForObject(
                "SELECT COUNT(*) FROM session_identity WHERE session_id = ? AND identity_state = 'DELETED'",
                Integer.class, sessionId.toString())).isEqualTo(1);
        assertThatThrownBy(() -> useCases.logSession(declared.id(), sessionId, occurredAt))
                .isInstanceOf(SessionDeletedException.class);
    }

    private Sankalpa runningSankalpa() {
        Sankalpa declared = useCases.declare("Walk", "", ActionType.PHYSICAL_ACTIVITY,
                clock.today(), PeriodUnit.DAY, 1, null);
        useCases.begin(declared.id(), clock.today().atStartOfDay());
        return declared;
    }

    private static void await(CountDownLatch latch) {
        try {
            if (!latch.await(5, TimeUnit.SECONDS)) throw new IllegalStateException("Timed out waiting for test latch");
        } catch (InterruptedException exception) {
            Thread.currentThread().interrupt();
            throw new IllegalStateException("Interrupted while waiting for test latch", exception);
        }
    }

    private static void await(CyclicBarrier barrier) {
        try {
            barrier.await(5, TimeUnit.SECONDS);
        } catch (InterruptedException exception) {
            Thread.currentThread().interrupt();
            throw new IllegalStateException("Interrupted while waiting for barrier", exception);
        } catch (BrokenBarrierException | TimeoutException exception) {
            throw new IllegalStateException("Timed out waiting for barrier", exception);
        }
    }
}
