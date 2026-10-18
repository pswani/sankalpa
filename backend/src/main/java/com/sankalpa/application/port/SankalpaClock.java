package com.sankalpa.application.port;

import java.time.LocalDate;
import java.time.LocalDateTime;

public interface SankalpaClock {
    LocalDateTime now();
    LocalDate today();
    default <T> T at(LocalDateTime moment, java.util.function.Supplier<T> action) { return action.get(); }
}
