package com.sankalpa.adapter.config;

import com.sankalpa.application.*;
import org.springframework.dao.*;
import java.sql.SQLException;
import java.util.function.Supplier;

final class PracticeTransactions {
    private PracticeTransactions() {}
    static <T> T retry(Supplier<T> transaction) {
        for (int attempt = 0; ; attempt++) {
            try { return transaction.get(); }
            catch (RuntimeException failure) {
                boolean collision = failure instanceof SessionIdentityClaimConflictException
                        || failure instanceof ExtensionClaimConflict;
                boolean contention = failure instanceof TransientDataAccessException;
                for (Throwable cause = failure; cause != null; cause = cause.getCause()) {
                    if (cause instanceof SQLException sql && ((sql.getErrorCode() & 255) == 5
                            || (sql.getErrorCode() & 255) == 6)) contention = true;
                }
                if (!collision && !contention) throw failure;
                if (attempt >= 2) throw new PracticeException("PRACTICE_WRITE_CONTENDED", "Practice is busy; retry this same action");
                // A SQLite snapshot collision returns immediately; give its winning transaction time to commit.
                try { Thread.sleep(20L * (attempt + 1)); }
                catch (InterruptedException interrupted) {
                    Thread.currentThread().interrupt();
                    throw new PracticeException("PRACTICE_WRITE_CONTENDED", "Practice action was interrupted; retry this same action");
                }
            }
        }
    }
}
