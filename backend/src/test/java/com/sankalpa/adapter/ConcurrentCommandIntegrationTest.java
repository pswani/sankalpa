package com.sankalpa.adapter;

import com.sankalpa.adapter.out.persistence.JdbcSankalpaPersistenceAdapter;
import com.sankalpa.application.SankalpaUseCases;
import com.sankalpa.application.port.SankalpaClock;
import com.sankalpa.domain.ActionType;
import com.sankalpa.domain.DomainException;
import com.sankalpa.domain.Sankalpa;
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
            return useCases.logSession(declared.id(), sessionAt);
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

    private static void await(CountDownLatch latch) {
        try {
            if (!latch.await(5, TimeUnit.SECONDS)) throw new IllegalStateException("Timed out waiting for test latch");
        } catch (InterruptedException exception) {
            Thread.currentThread().interrupt();
            throw new IllegalStateException("Interrupted while waiting for test latch", exception);
        }
    }
}
