package com.sankalpa.adapter.config;

import com.sankalpa.adapter.out.clock.SystemSankalpaClock;
import com.sankalpa.application.SankalpaService;
import com.sankalpa.application.SankalpaUseCases;
import com.sankalpa.application.port.SankalpaClock;
import com.sankalpa.application.port.SankalpaRepository;
import com.sankalpa.application.port.SessionRepository;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.context.annotation.Primary;
import org.springframework.transaction.PlatformTransactionManager;

import java.time.Clock;
import java.time.ZoneId;

@Configuration
public class ApplicationConfiguration {
    @Bean
    SankalpaClock sankalpaClock(@Value("${sankalpa.timezone:UTC}") String timezone) {
        return new SystemSankalpaClock(Clock.system(ZoneId.of(timezone)));
    }

    @Bean
    SankalpaService sankalpaService(SankalpaRepository sankalpas,
                                    SessionRepository sessions,
                                    SankalpaClock clock) {
        return new SankalpaService(sankalpas, sessions, clock);
    }

    @Bean
    @Primary
    SankalpaUseCases transactionalSankalpaUseCases(SankalpaService service,
                                                    PlatformTransactionManager manager) {
        return new TransactionalSankalpaUseCases(service, manager);
    }
}
