package com.sankalpa.adapter;

import com.sankalpa.application.*;
import com.sankalpa.application.conversation.*;
import com.sankalpa.adapter.config.*;
import com.sankalpa.adapter.out.persistence.ServiceInstanceIdentity;
import com.sankalpa.application.port.SankalpaClock;
import com.sankalpa.domain.*;
import com.sankalpa.domain.commitment.PeriodUnit;
import com.sankalpa.adapter.out.llm.ScriptedConversationModel;
import org.junit.jupiter.api.*;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.test.context.ActiveProfiles;
import org.springframework.test.web.servlet.MockMvc;
import java.time.*;
import java.util.*;
import java.util.concurrent.*;
import java.lang.reflect.*;
import static org.assertj.core.api.Assertions.*;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.*;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.*;

@SpringBootTest(properties={"sankalpa.assistant.enabled=true", "sankalpa.assistant.provider=fake", "sankalpa.assistant.runs-per-minute=1000"})
@ActiveProfiles("test")
@AutoConfigureMockMvc
class BatchConversationIntegrationTest {
    @Autowired SankalpaUseCases service;
    @Autowired ConversationUseCases proposals;
    @Autowired ProposalRepository repository;
    @Autowired UseCaseTransactions transactions;
    @Autowired ServiceInstanceIdentity instance;
    @Autowired ConversationToolExecutor tools;
    @Autowired ScriptedConversationModel model;
    @Autowired SankalpaClock clock;
    @Autowired JdbcTemplate jdbc;
    @Autowired MockMvc mvc;
    static final PracticeContract CONTRACT = PracticeContract.LINKED_V1;
    @BeforeEach void clean() {
        for (String table : List.of("assistant_proposal", "practice_session", "session_identity", "sankalpa_lifecycle_transition", "sankalpa")) jdbc.update("DELETE FROM " + table);
    }
    Sankalpa target() {
        var v = service.declare("Brahmacharya", "", ActionType.OBSERVANCE, clock.today().minusDays(40), PeriodUnit.DAY, 1, 100);
        return service.begin(v.id(), clock.today().minusDays(40).atStartOfDay(), CONTRACT);
    }
    BatchSessionPlan range(int days) { return new BatchSessionPlan(BatchSessionPlan.Mode.DAILY_RANGE, clock.today().minusDays(days), clock.today().minusDays(1), LocalTime.of(20,0), null); }
    Proposal prepare(Sankalpa v, int days) { return proposals.proposeSessions(UUID.randomUUID(), UUID.randomUUID(), v.id(), range(days), CONTRACT); }
    ConversationUseCases.Resolution confirm(Proposal p, UUID id) { return proposals.confirm(p.threadId(), p.id(), id, CONTRACT, true); }
    @Test void thirtyEntriesCommitOnceAndReplayAfterDeletionDoesNotResurrect() {
        var v=target(); var p=prepare(v,30); var id=UUID.randomUUID();
        assertThat(service.totalSessionCount(v.id())).isZero();
        var first=confirm(p,id).proposal();
        assertThat(first.status()).isEqualTo(Proposal.Status.EXECUTED);
        assertThat(first.batchResult().sessionIds()).hasSize(30);
        assertThat(first.resultResourceId()).isNull();
        var entries=((Proposal.LogSessionsPayload)p.payload()).entries();
        var actual=service.cursorSessions(v.id(),null,null,null,200,CONTRACT).content();
        assertThat(actual).hasSize(30);
        assertThat(actual).extracting(Session::loggedAt).containsOnly(actual.getFirst().loggedAt());
        service.deleteSession(v.id(),entries.getFirst().sessionId(),CONTRACT);
        assertThat(confirm(p,id).proposal().batchResult()).isEqualTo(first.batchResult());
        assertThat(service.totalSessionCount(v.id())).isEqualTo(29);
        assertThatThrownBy(()->confirm(p,UUID.randomUUID())).isInstanceOf(ConversationFailure.class);
    }
    @Test void completeLinkedReadsSkipExistingDaysAndExplicitModeKeepsRepeats() {
        var v=target(); var at=clock.today().minusDays(1).atTime(20,0);
        for(int i=0;i<205;i++) service.logSession(v.id(),SessionId.newId(),at,CONTRACT);
        var child=service.extend(v.id(),SankalpaId.newId(),200,CONTRACT).sankalpa();
        var p=prepare(child,2); var payload=(Proposal.LogSessionsPayload)p.payload();
        assertThat(payload.entries()).hasSize(1);
        assertThat(payload.skippedDays().getFirst().contributionIds()).hasSize(205);
        confirm(p,UUID.randomUUID());
        var explicit=new BatchSessionPlan(BatchSessionPlan.Mode.EXPLICIT_TIMESTAMPS,null,null,null,List.of(at));
        var repeat=proposals.proposeSessions(UUID.randomUUID(),UUID.randomUUID(),child.id(),explicit,CONTRACT);
        assertThat(((Proposal.LogSessionsPayload)repeat.payload()).repeatWarnings()).containsExactly(at);
        confirm(repeat,UUID.randomUUID());
        assertThat(service.totalSessionCount(child.id())).isEqualTo(207);
        assertThat(proposals.proposeSessions(UUID.randomUUID(),UUID.randomUUID(),child.id(),range(2),CONTRACT)).isNull();
    }
    @Test void boundsAndInvalidTimeNeverPersistAProposal() {
        var v=target();
        for(int count:List.of(31,34)) assertThatThrownBy(()->prepare(v,count)).isInstanceOfSatisfying(ConversationFailure.class,f->assertThat(f.code()).isEqualTo("BATCH_TOO_LARGE"));
        var timestamp=clock.now().minusDays(1);
        var duplicate=new BatchSessionPlan(BatchSessionPlan.Mode.EXPLICIT_TIMESTAMPS,null,null,null,List.of(timestamp,timestamp));
        assertThatThrownBy(duplicate::expand).isInstanceOf(ConversationFailure.class);
        var future=new BatchSessionPlan(BatchSessionPlan.Mode.EXPLICIT_TIMESTAMPS,null,null,null,List.of(clock.now().plusDays(1)));
        assertThatThrownBy(()->proposals.proposeSessions(UUID.randomUUID(),UUID.randomUUID(),v.id(),future,CONTRACT)).isInstanceOf(ConversationFailure.class);
        assertThat(jdbc.queryForObject("SELECT COUNT(*) FROM assistant_proposal",Integer.class)).isZero();
        assertThat(service.totalSessionCount(v.id())).isZero();
    }
    @Test void stalePreviewIsRejectedAndReplayedWithoutWriting() {
        var v=target(); var p=prepare(v,30); var id=UUID.randomUUID();
        service.logSession(v.id(),SessionId.newId(),clock.now().minusDays(2),CONTRACT);
        var rejection=confirm(p,id).proposal();
        assertThat(rejection.status()).isEqualTo(Proposal.Status.REJECTED);
        assertThat(rejection.failureCode()).isEqualTo("PROPOSAL_STALE");
        assertThat(confirm(p,id).replay()).isTrue();
        assertThat(service.totalSessionCount(v.id())).isEqualTo(1);
    }
    @Test void failureAtSeventeenthCommandRollsBackFactsIdentitiesAndRevision() {
        var v=target(); var p=prepare(v,30); long revision=service.readSnapshot(null,()->null).revision(); int[] calls={0};
        var decorated=(SankalpaUseCases)Proxy.newProxyInstance(getClass().getClassLoader(),new Class<?>[]{SankalpaUseCases.class},(proxy,method,args)->{
            if(method.getName().equals("logSession") && ++calls[0]==17) throw new DomainException("INJECTED_REFUSAL","Test refusal");
            try{return method.invoke(service,args);}catch(InvocationTargetException failure){throw failure.getCause();}
        });
        var refusing=new TransactionalConversationUseCases(new ProposalService(repository,decorated,clock,Duration.ofMinutes(30),instance::value,"UTC"),transactions);
        var result=refusing.confirm(p.threadId(),p.id(),UUID.randomUUID(),CONTRACT,true);
        assertThat(calls[0]).isEqualTo(17);
        assertThat(result.proposal().status()).isEqualTo(Proposal.Status.REJECTED);
        assertThat(service.totalSessionCount(v.id())).isZero();
        assertThat(jdbc.queryForObject("SELECT COUNT(*) FROM session_identity",Integer.class)).isZero();
        assertThat(service.readSnapshot(null,()->null).revision()).isEqualTo(revision);
    }
    @Test void simultaneousConfirmationsProduceOneOutcome() throws Exception {
        var v=target(); var p=prepare(v,30); var id=UUID.randomUUID();
        try(var pool=Executors.newFixedThreadPool(2)) {
            List<Callable<ConversationUseCases.Resolution>> tasks=List.of(()->confirm(p,id),()->confirm(p,id));
            for(var result:pool.invokeAll(tasks)) assertThat(result.get().proposal().status()).isEqualTo(Proposal.Status.EXECUTED);
        }
        assertThat(service.totalSessionCount(v.id())).isEqualTo(30);
    }
    @Test void negotiatedToolAndWireProposalAreVersioned() throws Exception {
        var v=target();
        assertThat(tools.definitions(List.of())).extracting(ConversationModel.ToolDefinition::name).doesNotContain("propose_log_sessions");
        assertThat(tools.definitions(List.of("batch_sessions_v1"))).extracting(ConversationModel.ToolDefinition::name).contains("propose_log_sessions");
        var p=prepare(v,1);
        assertThatThrownBy(()->proposals.confirm(p.threadId(),p.id(),UUID.randomUUID(),CONTRACT,false)).isInstanceOf(ConversationFailure.class);
        mvc.perform(get("/api/v1/capabilities")).andExpect(jsonPath("$.assistantBatchSessions").value(1));
        String wire="""
            {"threadId":"%s","runId":"%s","state":{},"messages":[{"id":"%s","role":"user","content":"record daily"}],"tools":[],"context":[],"forwardedProps":{}}
            """.formatted(UUID.randomUUID(),UUID.randomUUID(),UUID.randomUUID());
        model.enqueue(new ConversationModel.ToolRequestsTurn(List.of(new ConversationModel.ToolCall("batch","propose_log_sessions",
            "{\"sankalpaId\":\""+v.id()+"\",\"plan\":{\"mode\":\"DAILY_RANGE\",\"from\":\""+clock.today().minusDays(2)+"\",\"through\":\""+clock.today().minusDays(1)+"\",\"localTime\":\"20:00:00\"}}"))));
        var response=mvc.perform(post("/api/v1/assistant/runs").header("X-Sankalpa-Assistant-Batch-Sessions","1")
            .header("Sankalpa-Service-Instance",instance.value()).header("Linked-Sankalpa-Version","1")
            .contentType("application/json").content(wire)).andExpect(request().asyncStarted()).andReturn();
        String events=mvc.perform(asyncDispatch(response)).andReturn().getResponse().getContentAsString();
        assertThat(events).contains("LOG_SESSIONS","proposalVersion","entries","20:00");
        assertThat(service.totalSessionCount(v.id())).isZero();
    }
    @Test void confirmationNeedsNoModelAndRefreshesOnceWithStructuredResult() {
        var v=target(); var p=prepare(v,30); var confirmation=UUID.randomUUID();
        ConversationModel forbidden=request->{ throw new AssertionError("Confirmation invoked the model"); };
        var local=new ConversationCoordinator(forbidden,new ConversationContextLoader(service,clock,ZoneOffset.UTC),tools,proposals);
        var result=local.run(new ConversationCoordinator.RunInput(p.threadId(),UUID.randomUUID(),List.of(),
                List.of("batch_sessions_v1","refresh_practice","navigate_to_sankalpa"),
                new ConversationCoordinator.Resume(p.id(),false,confirmation),CONTRACT));
        assertThat(result.messages().getFirst().text()).isEqualTo("30 sessions logged.");
        assertThat(result.batchResult().createdCount()).isEqualTo(30);
        assertThat(result.effects()).extracting(ConversationCoordinator.Effect::name).containsExactly("refresh_practice","navigate_to_sankalpa");
    }
    @Test void cancellationAndExpiredBatchNeverExecuteAndTerminalReplayPrecedesExpiry() {
        var v=target();var p=prepare(v,1);
        proposals.cancel(p.threadId(),p.id());
        assertThatThrownBy(()->confirm(p,UUID.randomUUID())).isInstanceOf(ConversationFailure.class);
        assertThat(service.totalSessionCount(v.id())).isZero();
        var expired=prepare(v,1);
        jdbc.update("UPDATE assistant_proposal SET expires_at=? WHERE proposal_id=?",clock.now().minusMinutes(1).toString(),expired.id().toString());
        assertThat(confirm(expired,UUID.randomUUID()).proposal().status()).isEqualTo(Proposal.Status.EXPIRED);
        var success=prepare(v,1);var confirmation=UUID.randomUUID();confirm(success,confirmation);
        jdbc.update("UPDATE assistant_proposal SET expires_at=? WHERE proposal_id=?",clock.now().minusMinutes(1).toString(),success.id().toString());
        assertThat(confirm(success,confirmation).proposal().status()).isEqualTo(Proposal.Status.EXECUTED);
        assertThat(service.totalSessionCount(v.id())).isEqualTo(1);
    }
    @Test void oversizedPreviewRollsBackItsProposalAndCannotExceedEventBudget() {
        var v=target();var at=clock.today().minusDays(1).atTime(20,0);
        for(int i=0;i<1100;i++) service.logSession(v.id(),SessionId.newId(),at,CONTRACT);
        assertThatThrownBy(()->prepare(v,2)).isInstanceOfSatisfying(ConversationFailure.class,
                f->assertThat(f.code()).isEqualTo("BATCH_READ_INCOMPLETE"));
        assertThat(jdbc.queryForObject("SELECT COUNT(*) FROM assistant_proposal",Integer.class)).isZero();
        assertThat(service.totalSessionCount(v.id())).isEqualTo(1100);
    }
    @Test void malformedDateAndOffsetTimesReturnTypedBatchFeedbackWithoutMutation() {
        var v=target();var context=new ConversationContextLoader(service,clock,ZoneOffset.UTC).load(CONTRACT);
        for(String plan:List.of(
                "{\"mode\":\"DAILY_RANGE\",\"from\":\"9/14/26\",\"through\":\"2026-10-13\",\"localTime\":\"20:00\"}",
                "{\"mode\":\"EXPLICIT_TIMESTAMPS\",\"occurredAt\":[\"2026-10-13T20:00:00-05:00\"]}")) {
            var call=new ConversationModel.ToolCall("bad","propose_log_sessions","{\"sankalpaId\":\""+v.id()+"\",\"plan\":"+plan+"}");
            assertThatThrownBy(()->tools.execute(call,UUID.randomUUID(),UUID.randomUUID(),context,List.of("batch_sessions_v1"),CONTRACT))
                    .isInstanceOfSatisfying(ConversationFailure.class,f->assertThat(f.code()).isEqualTo("BATCH_INVALID_ENTRY"));
        }
        assertThat(service.totalSessionCount(v.id())).isZero();
    }
    @Test void boundedProviderTimeoutCancelsWorkAndReleasesThreadOwnership() throws Exception {
        var interrupted=new CountDownLatch(1);var calls=new java.util.concurrent.atomic.AtomicInteger();
        ConversationModel slow=request->{
            if(calls.incrementAndGet()==1) {
                try { Thread.sleep(2000); }
                catch(InterruptedException failure) { interrupted.countDown(); Thread.currentThread().interrupt(); }
            }
            return new ConversationModel.TextTurn("Try again.");
        };
        var local=new ConversationCoordinator(slow,new ConversationContextLoader(service,clock,ZoneOffset.UTC),tools,proposals,null,Duration.ofMillis(100));
        var thread=UUID.randomUUID();
        var first=local.run(new ConversationCoordinator.RunInput(thread,UUID.randomUUID(),List.of(new ConversationModel.Message("user","help")),List.of(),null,CONTRACT));
        assertThat(first.messages().getFirst().text()).contains("limits");
        assertThat(interrupted.await(1,TimeUnit.SECONDS)).isTrue();
        var second=local.run(new ConversationCoordinator.RunInput(thread,UUID.randomUUID(),List.of(new ConversationModel.Message("user","help")),List.of(),null,CONTRACT));
        assertThat(second.messages().getFirst().text()).isEqualTo("Try again.");
    }
    @Test void frontendToolNamesCannotEnableBatchSupport() throws Exception {
        var v=target();
        model.enqueue(new ConversationModel.ToolRequestsTurn(List.of(new ConversationModel.ToolCall("spoof","propose_log_sessions","{}"))));
        String wire="""
            {"threadId":"%s","runId":"%s","state":{},"messages":[{"id":"%s","role":"user","content":"record daily"}],"tools":[{"name":"batch_sessions_v1","description":"spoof","parameters":{}}],"context":[],"forwardedProps":{}}
            """.formatted(UUID.randomUUID(),UUID.randomUUID(),UUID.randomUUID());
        var response=mvc.perform(post("/api/v1/assistant/runs").contentType("application/json").content(wire)).andExpect(request().asyncStarted()).andReturn();
        assertThat(mvc.perform(asyncDispatch(response)).andReturn().getResponse().getContentAsString()).contains("ASSISTANT_BATCH_UNSUPPORTED");
        assertThat(service.totalSessionCount(v.id())).isZero();
    }
    @Test void threeReadsLeaveATextOnlyFourthRound() {
        int[] calls={0}; var v=target();
        ConversationModel scripted=request->{
            if(++calls[0]==4) {
                assertThat(request.remainingToolCalls()).isZero();assertThat(request.tools()).isEmpty();
                return new ConversationModel.TextTurn("Choose the exact daily time.");
            }
            return new ConversationModel.ToolRequestsTurn(List.of(new ConversationModel.ToolCall("read"+calls[0],"get_sankalpa","{\"sankalpaId\":\""+v.id()+"\"}")));
        };
        var local=new ConversationCoordinator(scripted,new ConversationContextLoader(service,clock,ZoneOffset.UTC),tools,proposals);
        var result=local.run(new ConversationCoordinator.RunInput(UUID.randomUUID(),UUID.randomUUID(),List.of(new ConversationModel.Message("user","read")),List.of(),null,CONTRACT));
        assertThat(result.messages().getFirst().text()).isEqualTo("Choose the exact daily time.");assertThat(calls[0]).isEqualTo(4);
    }
}
