package com.sankalpa.adapter.config;

import java.util.function.Supplier;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.TransactionDefinition;
import org.springframework.transaction.support.TransactionSynchronizationManager;
import org.springframework.transaction.support.TransactionTemplate;

public final class JdbcUseCaseTransactions implements UseCaseTransactions {
    private final TransactionTemplate read;
    private final TransactionTemplate write;
    public JdbcUseCaseTransactions(PlatformTransactionManager manager) {
        read = new TransactionTemplate(manager);
        read.setIsolationLevel(TransactionDefinition.ISOLATION_SERIALIZABLE);
        write = new TransactionTemplate(manager);
    }
    public <T> T read(Supplier<T> action) { return read.execute(status -> action.get()); }
    public <T> T write(Supplier<T> action) {
        if (TransactionSynchronizationManager.isActualTransactionActive()) return action.get();
        return PracticeTransactions.retry(() -> write.execute(status -> action.get()));
    }
}
