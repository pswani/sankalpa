package com.sankalpa.adapter;

import com.sankalpa.application.*;
import com.sankalpa.application.conversation.*;
import com.sankalpa.application.port.SankalpaClock;
import com.sankalpa.adapter.config.*;
import com.sankalpa.adapter.out.clock.SystemSankalpaClock;
import com.sankalpa.adapter.out.persistence.ServiceInstanceIdentity;
import com.sankalpa.domain.*;
import com.sankalpa.domain.commitment.PeriodUnit;
import org.junit.jupiter.api.*;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.context.TestConfiguration;
import org.springframework.context.annotation.*;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.test.context.ActiveProfiles;
import java.time.*;
import java.util.*;
import java.lang.reflect.*;
import static org.assertj.core.api.Assertions.*;

@SpringBootTest(properties={"sankalpa.assistant.enabled=true","sankalpa.assistant.provider=fake"})
@ActiveProfiles("test")
@Import(ObservanceHistoryRepairTest.FixedTime.class)
class ObservanceHistoryRepairTest {
    @TestConfiguration static class FixedTime {
        @Bean @Primary SankalpaClock repairClock() {
            return new SystemSankalpaClock(Clock.fixed(Instant.parse("2026-10-18T03:21:00Z"),ZoneId.of("America/Chicago")));
        }
    }
    @Autowired SankalpaUseCases service;
    @Autowired SankalpaService core;
    @Autowired ConversationUseCases proposals;
    @Autowired ProposalRepository repository;
    @Autowired UseCaseTransactions transactions;
    @Autowired SankalpaClock clock;
    @Autowired ServiceInstanceIdentity identity;
    @Autowired ConversationToolExecutor tools;
    @Autowired JdbcTemplate jdbc;
    static final PracticeContract CONTRACT=PracticeContract.LINKED_V1;
    static final LocalDateTime ORIGINAL=LocalDateTime.parse("2026-10-17T18:08:54.846005440");
    static final LocalDateTime EARLIER=LocalDateTime.parse("2026-09-14T00:01:00");
    @BeforeEach void clean() {
        for(String table:List.of("assistant_proposal","practice_session","session_identity","sankalpa_lifecycle_transition","sankalpa")) jdbc.update("DELETE FROM "+table);
    }
    Sankalpa target() {
        var vow=service.declare("Brahmacharya","Daily observance",ActionType.OBSERVANCE,LocalDate.of(2026,9,14),PeriodUnit.DAY,1,32);
        return service.begin(vow.id(),ORIGINAL,CONTRACT);
    }
    BatchSessionPlan plan() {return new BatchSessionPlan(BatchSessionPlan.Mode.DAILY_RANGE,EARLIER.toLocalDate(),LocalDate.of(2026,10,13),EARLIER.toLocalTime(),null);}
    Proposal prepare(Sankalpa v) {return proposals.proposeSessions(UUID.randomUUID(),UUID.randomUUID(),v.id(),plan(),CONTRACT,true);}
    ConversationUseCases.Resolution confirm(Proposal p,UUID confirmation) {return proposals.confirm(p.threadId(),p.id(),confirmation,CONTRACT,true,true);}
    @Test void screenshotMismatchIsExplainedOnOldClientAndRepairedOnlyAfterNewClientApproval() {
        var v=target();
        assertThatThrownBy(()->proposals.proposeSessions(UUID.randomUUID(),UUID.randomUUID(),v.id(),plan(),CONTRACT))
                .isInstanceOfSatisfying(ConversationFailure.class,f->{
                    assertThat(f.details()).containsEntry("domainCode","SANKALPA_NOT_IN_PROGRESS").containsEntry("beganAt",ORIGINAL.toString());
                    assertThat(f.getMessage()).contains("Changing the daily time", "2026-10-17");
                });
        var p=prepare(v);var payload=(Proposal.LogSessionsPayload)p.payload();
        assertThat(p.schemaVersion()).isEqualTo(3);assertThat(payload.entries()).hasSize(30);
        assertThat(payload.beginAdjustment().correctedEffectiveAt()).isEqualTo(EARLIER);
        assertThat(service.lifecycleHistory(v.id(),CONTRACT).getFirst().effectiveAt()).isEqualTo(ORIGINAL);
        assertThatThrownBy(()->proposals.confirm(p.threadId(),p.id(),UUID.randomUUID(),CONTRACT,true)).isInstanceOf(ConversationFailure.class);
        var confirmation=UUID.randomUUID();confirm(p,confirmation);
        var begin=service.lifecycleHistory(v.id(),CONTRACT).getFirst();
        assertThat(begin.effectiveAt()).isEqualTo(EARLIER);
        assertThat(begin.beginCorrections()).hasSize(1);
        assertThat(begin.beginCorrections().getFirst().previousEffectiveAt()).isEqualTo(ORIGINAL);
        assertThat(service.totalSessionCount(v.id())).isEqualTo(30);
        assertThat(confirm(p,confirmation).replay()).isTrue();
        assertThat(service.lifecycleHistory(v.id(),CONTRACT).getFirst().beginCorrections()).hasSize(1);
        PracticeValidation.validate(service.list(CONTRACT),service.cursorSessions(v.id(),null,null,null,200,CONTRACT).content());
        // Later extension inherits both corrected eligibility and the immutable original audit.
        var child=service.extend(v.id(),SankalpaId.newId(),90,CONTRACT).sankalpa();
        assertThat(child.lifecycle().transitions().getFirst()).isEqualTo(begin);
        assertThat(service.totalSessionCount(child.id())).isEqualTo(30);
    }
    @Test void cancellationDoesNotCorrectBeginOrLogAnything() {
        var v=target();var p=prepare(v);proposals.cancel(p.threadId(),p.id());
        assertThat(service.lifecycleHistory(v.id(),CONTRACT).getFirst().effectiveAt()).isEqualTo(ORIGINAL);
        assertThat(service.lifecycleHistory(v.id(),CONTRACT).getFirst().beginCorrections()).isEmpty();
        assertThat(service.totalSessionCount(v.id())).isZero();
    }
    @Test void lateFailureRollsBackCorrectionItsAuditAndEverySession() {
        var v=target();var p=prepare(v);long revision=service.readSnapshot(null,()->null).revision();int[] calls={0};
        var failing=(SankalpaUseCases)Proxy.newProxyInstance(getClass().getClassLoader(),new Class<?>[]{SankalpaUseCases.class},(proxy,method,args)->{
            if(method.getName().equals("logSession") && ++calls[0]==17)throw new DomainException("INJECTED","Late refusal");
            try{return method.invoke(core,args);}catch(InvocationTargetException failure){throw failure.getCause();}
        });
        var failingProposals=new TransactionalConversationUseCases(new ProposalService(repository,failing,clock,Duration.ofMinutes(30),identity::value,"America/Chicago"),transactions);
        assertThat(failingProposals.confirm(p.threadId(),p.id(),UUID.randomUUID(),CONTRACT,true,true).proposal().status()).isEqualTo(Proposal.Status.REJECTED);
        assertThat(service.lifecycleHistory(v.id(),CONTRACT).getFirst().effectiveAt()).isEqualTo(ORIGINAL);
        assertThat(service.lifecycleHistory(v.id(),CONTRACT).getFirst().beginCorrections()).isEmpty();
        assertThat(service.totalSessionCount(v.id())).isZero();
        assertThat(service.readSnapshot(null,()->null).revision()).isEqualTo(revision);
    }
    @Test void laterTransitionsAndLinkedHistoryAreNeverRewritten() {
        var paused=target();service.pause(paused.id(),CONTRACT);
        assertThatThrownBy(()->prepare(paused)).isInstanceOf(ConversationFailure.class);
        var linked=target();service.extend(linked.id(),SankalpaId.newId(),90,CONTRACT);
        assertThatThrownBy(()->prepare(linked)).isInstanceOf(ConversationFailure.class);
        assertThat(service.lifecycleHistory(linked.id(),CONTRACT).getFirst().effectiveAt()).isEqualTo(ORIGINAL);
    }
    @Test void chosenRecordingTimeDoesNotInvalidateAnAlreadyRecordedDayOrRequireUnnecessaryCorrection() {
        var v=service.declare("Observe","",ActionType.OBSERVANCE,EARLIER.toLocalDate(),PeriodUnit.DAY,1,32);
        service.begin(v.id(),EARLIER.toLocalDate().atTime(12,0),CONTRACT);
        service.logSession(v.id(),SessionId.newId(),EARLIER.toLocalDate().atTime(13,0),CONTRACT);
        var p=prepare(v);var payload=(Proposal.LogSessionsPayload)p.payload();
        assertThat(payload.entries()).hasSize(29);assertThat(payload.skippedDays()).hasSize(1);
        assertThat(payload.beginAdjustment()).isNull();
    }
    @Test void alreadyRecordedFeedbackNamesOnlyTheDatesActuallyVerified() {
        var v=service.declare("Observed", "",ActionType.OBSERVANCE,EARLIER.toLocalDate(),PeriodUnit.DAY,1,32);
        service.begin(v.id(),EARLIER,CONTRACT);
        service.logSession(v.id(),SessionId.newId(),EARLIER,CONTRACT);
        var context=new ConversationContextLoader(service,clock,ZoneId.of("America/Chicago")).load(CONTRACT);
        var args="{\"sankalpaId\":\""+v.id()+"\",\"plan\":{\"mode\":\"DAILY_RANGE\",\"from\":\"2026-09-14\",\"through\":\"2026-09-14\",\"localTime\":null}}";
        var result=(ConversationToolExecutor.ReadResult)tools.execute(new ConversationModel.ToolCall("scope","propose_log_sessions",args),UUID.randomUUID(),UUID.randomUUID(),context,List.of("batch_sessions_v1","begin_correction_v1"),CONTRACT);
        assertThat(result.json()).contains("verifiedDates", "2026-09-14", "nothing about other dates");
        assertThat(result.json()).doesNotContain("2026-09-15");
    }
    @Test void absentObservanceTimeIsASuggestedConventionInTheReviewNotAFabricatedExactPerformance() {
        var v=target();var context=new ConversationContextLoader(service,clock,ZoneId.of("America/Chicago")).load(CONTRACT);
        var args="{\"sankalpaId\":\""+v.id()+"\",\"plan\":{\"mode\":\"DAILY_RANGE\",\"from\":\"2026-09-14\",\"through\":\"2026-10-13\",\"localTime\":null}}";
        var outcome=(ConversationToolExecutor.ProposalResult)tools.execute(new ConversationModel.ToolCall("history","propose_log_sessions",args),UUID.randomUUID(),UUID.randomUUID(),context,List.of("batch_sessions_v1","begin_correction_v1"),CONTRACT);
        assertThat(outcome.proposal().schemaVersion()).isEqualTo(3);
        assertThat(((Proposal.LogSessionsPayload)outcome.proposal().payload()).plan().recordingTimeSuggested()).isTrue();
        assertThat(service.totalSessionCount(v.id())).isZero();
    }
    @Test void finiteCoverageStillRefusesDatesAfterOctoberFifteenth() {
        var v=target();var longer=new BatchSessionPlan(BatchSessionPlan.Mode.DAILY_RANGE,LocalDate.of(2026,10,14),LocalDate.of(2026,10,17),LocalTime.of(0,1),null);
        assertThatThrownBy(()->proposals.proposeSessions(UUID.randomUUID(),UUID.randomUUID(),v.id(),longer,CONTRACT,true))
                .isInstanceOfSatisfying(ConversationFailure.class,f->assertThat(f.details()).containsEntry("commitmentEnd","2026-10-15"));
        assertThat(service.totalSessionCount(v.id())).isZero();
    }
}
