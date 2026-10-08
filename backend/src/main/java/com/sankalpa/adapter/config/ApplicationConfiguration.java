package com.sankalpa.adapter.config;

import com.sankalpa.adapter.out.clock.SystemSankalpaClock;
import com.sankalpa.application.SankalpaService;
import com.sankalpa.application.SankalpaUseCases;
import com.sankalpa.application.port.SankalpaClock;
import com.sankalpa.application.port.SankalpaRepository;
import com.sankalpa.application.port.SessionRepository;
import com.sankalpa.application.conversation.ConversationUseCases;
import com.sankalpa.application.conversation.ProposalRepository;
import com.sankalpa.application.conversation.ProposalService;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.context.annotation.Primary;
import org.springframework.transaction.PlatformTransactionManager;

import java.time.Clock;
import java.time.ZoneId;
import java.time.Duration;

@Configuration
public class ApplicationConfiguration {
    @Bean
    org.springframework.boot.autoconfigure.jackson.Jackson2ObjectMapperBuilderCustomizer wholeNumberRequests() {
        return builder -> builder.featuresToDisable(com.fasterxml.jackson.databind.DeserializationFeature.ACCEPT_FLOAT_AS_INT);
    }

    @Bean
    SankalpaClock sankalpaClock(@Value("${sankalpa.timezone}") String timezone) {
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

    /**
     * Receives the undecorated service: every proposal call already runs inside the transaction
     * owned by {@link TransactionalConversationUseCases}. A nested transactional wrapper would mark
     * that shared transaction rollback-only on a domain refusal, losing the REJECTED status.
     */
    @Bean
    ProposalService proposalService(ProposalRepository proposals, SankalpaService sankalpas,
                                    SankalpaClock clock,
                                    @Value("${sankalpa.assistant.proposal-lifetime:PT30M}") Duration lifetime) {
        return new ProposalService(proposals, sankalpas, clock, lifetime);
    }

    @Bean
    @Primary
    ConversationUseCases transactionalConversationUseCases(ProposalService service,
                                                            PlatformTransactionManager manager) {
        return new TransactionalConversationUseCases(service, manager);
    }
}
