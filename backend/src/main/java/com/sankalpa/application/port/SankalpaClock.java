package com.sankalpa.application.port;

import java.time.LocalDate;
import java.time.LocalDateTime;

public interface SankalpaClock {
    LocalDateTime now();
    LocalDate today();
}
