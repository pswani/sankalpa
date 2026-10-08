package com.sankalpa.adapter;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.sankalpa.application.*;
import com.sankalpa.application.port.SankalpaClock;
import com.sankalpa.domain.*;
import com.sankalpa.domain.commitment.PeriodUnit;
import com.sankalpa.domain.lifecycle.*;
import com.sankalpa.adapter.out.persistence.ServiceInstanceIdentity;
import org.junit.jupiter.api.*;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.boot.test.context.*;
import org.springframework.context.annotation.*;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.test.context.ActiveProfiles;
import org.springframework.test.web.servlet.*;
import org.springframework.test.web.servlet.request.MockHttpServletRequestBuilder;
import java.time.*;
import java.util.*;
import java.util.concurrent.*;
import static org.assertj.core.api.Assertions.*;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.*;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.*;

@SpringBootTest
@AutoConfigureMockMvc
@ActiveProfiles("test")
@Import(LinkedExtensionsIntegrationTest.Configuration.class)
class LinkedExtensionsIntegrationTest {
    @Autowired SankalpaUseCases service;
    @Autowired JdbcTemplate jdbc;
    @Autowired MockMvc mvc;
    @Autowired ObjectMapper json;
    @Autowired ServiceInstanceIdentity identity;
    @Autowired MutableClock clock;
    @Autowired com.sankalpa.application.conversation.ConversationUseCases proposals;
    static final PracticeContract LINKED=PracticeContract.LINKED_V1;
    @TestConfiguration static class Configuration {
        @Bean @Primary MutableClock clock(){return new MutableClock();}
    }
    static class MutableClock implements SankalpaClock {
        volatile LocalDateTime now=LocalDateTime.of(2026,7,30,12,0);
        public LocalDateTime now(){return now;}
        public LocalDate today(){return now.toLocalDate();}
    }
    @BeforeEach void clean() {
        jdbc.update("DELETE FROM practice_session");jdbc.update("DELETE FROM session_identity");
        jdbc.update("DELETE FROM sankalpa_lifecycle_transition");jdbc.update("DELETE FROM sankalpa");
        clock.now=LocalDateTime.of(2026,7,30,12,0);
    }
    Sankalpa source() {
        var s=service.declare("Vipassana","Sit",ActionType.MEDITATION,LocalDate.of(2026,7,1),PeriodUnit.DAY,1,40);
        return service.begin(s.id(),LocalDate.of(2026,7,1).atStartOfDay());
    }
    Sankalpa child(Sankalpa source) {return service.extend(source.id(),SankalpaId.newId(),90,LINKED).sankalpa();}
    MockHttpServletRequestBuilder linked(MockHttpServletRequestBuilder request) {
        return request.header("Linked-Sankalpa-Version","1").header("Sankalpa-Service-Instance",identity.value());
    }
    Session log(Sankalpa owner,LocalDateTime at) {return service.logSession(owner.id(),SessionId.newId(),at,LINKED).session();}

    @Test void separateWinsSharedHistoryAndUniqueJournal() throws Exception {
        var root=source();
        for(int day=1;day<=30;day++)log(root,LocalDate.of(2026,7,day).atTime(8,0));
        var longer=child(root);
        assertThat(longer.commitment().endDate()).contains(LocalDate.of(2026,9,28));
        assertThat(service.totalSessionCount(root.id())).isEqualTo(30);
        assertThat(service.totalSessionCount(longer.id())).isEqualTo(30);
        assertThat(longer.lifecycle().transitions()).isEqualTo(root.lifecycle().transitions());
        mvc.perform(linked(get("/api/v1/sessions"))).andExpect(status().isOk())
                .andExpect(jsonPath("$.content.length()").value(30))
                .andExpect(jsonPath("$.content[0].contributingSankalpaIds.length()").value(2));
        clock.now=LocalDateTime.of(2026,8,10,12,0);
        service.complete(root.id(),CompletionOutcome.SUCCESSFUL,LINKED);
        log(longer,clock.now.minusHours(1));
        assertThat(service.totalSessionCount(root.id())).isEqualTo(30);
        assertThat(service.totalSessionCount(longer.id())).isEqualTo(31);
        var longest=service.extend(longer.id(),SankalpaId.newId(),180,LINKED).sankalpa();
        assertThat(longest.lifecycle().current()).isEqualTo(LifecycleState.IN_PROGRESS);
        assertThat(service.totalSessionCount(longest.id())).isEqualTo(31);
        clock.now=LocalDateTime.of(2026,9,29,12,0);
        service.complete(longer.id(),CompletionOutcome.SUCCESSFUL,LINKED);
        assertThat(service.linkedSeries(root.id(),LINKED)).filteredOn(v->v.lifecycle().current()==LifecycleState.COMPLETED_SUCCESSFULLY).hasSize(2);
        assertThat(longest.lifecycle().transitions().getFirst().originSankalpaId()).isEqualTo(root.id());
        mvc.perform(linked(get("/api/v1/sankalpas/"+root.id()+"/linked-series")))
                .andExpect(status().isOk()).andExpect(jsonPath("$.length()").value(3));
    }
    @Test void independentPauseAndLoggingOwnerEligibility() {
        var root=source();var longer=child(root);
        clock.now=LocalDateTime.of(2026,7,31,0,0);service.pause(longer.id(),LINKED);
        clock.now=clock.now.plusHours(12);
        log(root,clock.now.minusHours(1));
        assertThat(service.totalSessionCount(root.id())).isEqualTo(1);
        assertThat(service.totalSessionCount(longer.id())).isZero();
        assertThatThrownBy(()->log(longer,clock.now.minusHours(1))).isInstanceOf(DomainException.class);
        service.resume(longer.id(),LINKED);log(longer,clock.now);
        assertThat(service.totalSessionCount(root.id())).isEqualTo(2);
        assertThat(service.totalSessionCount(longer.id())).isEqualTo(1);
    }
    @Test void deletionUsesOriginalOwnerAndKeepsCompletion() throws Exception {
        var root=source();var fact=log(root,LocalDate.of(2026,7,10).atTime(8,0));var longer=child(root);
        service.complete(root.id(),CompletionOutcome.SUCCESSFUL,LINKED);
        mvc.perform(linked(get("/api/v1/sankalpas/"+longer.id()+"/sessions")))
                .andExpect(status().isOk()).andExpect(jsonPath("$.content[0].loggingSankalpaId").value(root.id().toString()));
        assertThatThrownBy(()->service.deleteSession(longer.id(),fact.id(),LINKED)).isInstanceOf(SessionIdentityConflictException.class);
        service.deleteSession(root.id(),fact.id(),LINKED);
        assertThat(service.totalSessionCount(root.id())).isZero();assertThat(service.totalSessionCount(longer.id())).isZero();
        assertThat(service.detail(root.id(),LINKED).lifecycle().current()).isEqualTo(LifecycleState.COMPLETED_SUCCESSFULLY);
        service.deleteSession(root.id(),fact.id());
        assertThatThrownBy(()->service.logSession(root.id(),fact.id(),fact.occurredAt(),LINKED)).isInstanceOf(SessionDeletedException.class);
    }
    @Test void extensionReplaySurvivesSourceCompletionAndChildStateChanges() {
        var root=source();var id=SankalpaId.newId();var first=service.extend(root.id(),id,90,LINKED);
        service.complete(root.id(),CompletionOutcome.SUCCESSFUL,LINKED);service.pause(id,LINKED);
        long revision=service.readSnapshot(null,()->0).revision();
        var replay=service.extend(root.id(),id,90,LINKED);
        assertThat(replay.created()).isFalse();assertThat(replay.sankalpa().declaredAt()).isEqualTo(first.sankalpa().declaredAt());
        assertThat(replay.sankalpa().lifecycle().current()).isEqualTo(LifecycleState.PAUSED);
        assertThat(service.readSnapshot(null,()->0).revision()).isEqualTo(revision);
        assertThatThrownBy(()->service.extend(root.id(),id,91,LINKED)).isInstanceOf(PracticeException.class)
                .extracting("code").isEqualTo("EXTENSION_IDENTITY_CONFLICT");
        assertThatThrownBy(()->service.extend(root.id(),SankalpaId.newId(),120,LINKED)).isInstanceOf(PracticeException.class)
                .extracting("code").isEqualTo("EXTENSION_ALREADY_EXISTS");
    }
    @Test void cursorScansThroughMultipleIneligibleChunks() throws Exception {
        var root=source();var old=log(root,LocalDate.of(2026,7,10).atTime(8,0));var longer=child(root);
        clock.now=LocalDateTime.of(2026,7,31,0,0);service.pause(longer.id(),LINKED);clock.now=clock.now.plusHours(12);
        for(int i=0;i<250;i++)log(root,clock.now.minusHours(1));
        mvc.perform(linked(get("/api/v1/sankalpas/"+longer.id()+"/sessions").param("size","1")))
                .andExpect(status().isOk()).andExpect(jsonPath("$.content.length()").value(1))
                .andExpect(jsonPath("$.content[0].id").value(old.id().toString())).andExpect(jsonPath("$.hasMore").value(false));
        assertThat(service.totalSessionCount(longer.id())).isEqualTo(1);
    }
    @Test void cursorAndReadRevisionPreventMixedSnapshots() throws Exception {
        var root=source();log(root,clock.now.minusHours(2));log(root,clock.now.minusHours(1));
        var first=mvc.perform(linked(get("/api/v1/sessions").param("size","1"))).andExpect(status().isOk()).andReturn().getResponse();
        String token=json.readTree(first.getContentAsString()).path("nextCursor").asText();
        mvc.perform(linked(get("/api/v1/sessions").param("cursor",token))).andExpect(status().isOk()).andExpect(jsonPath("$.content.length()").value(1));
        mvc.perform(linked(get("/api/v1/sankalpas/"+root.id()+"/sessions").param("cursor",token)))
                .andExpect(status().isBadRequest()).andExpect(jsonPath("$.code").value("INVALID_SESSION_CURSOR"));
        log(root,clock.now);
        mvc.perform(linked(get("/api/v1/sessions").param("cursor",token)))
                .andExpect(status().isConflict()).andExpect(jsonPath("$.code").value("READ_SNAPSHOT_CHANGED"));
        mvc.perform(linked(get("/api/v1/sankalpas").header("Sankalpa-Practice-Revision",first.getHeader("Sankalpa-Practice-Revision"))))
                .andExpect(status().isConflict()).andExpect(jsonPath("$.code").value("READ_SNAPSHOT_CHANGED"));
    }
    @Test void legacyGateAndNonmutatingIdentityReplay() throws Exception {
        var root=source();var fact=log(root,clock.now.minusHours(1));child(root);
        mvc.perform(get("/api/v1/sankalpas")).andExpect(status().isConflict()).andExpect(jsonPath("$.code").value("LINKED_SANKALPA_UPGRADE_REQUIRED"));
        mvc.perform(post("/api/v1/sankalpas/"+root.id()+"/pause")).andExpect(status().isConflict());
        assertThat(service.logSession(root.id(),fact.id(),fact.occurredAt()).created()).isFalse();
        assertThatThrownBy(()->service.logSession(root.id(),SessionId.newId(),fact.occurredAt())).isInstanceOf(PracticeException.class);
        assertThatThrownBy(()->service.deleteSession(root.id(),fact.id())).isInstanceOf(PracticeException.class);
        assertThat(service.totalSessionCount(root.id())).isEqualTo(1);
    }
    @Test void extensionHttpIdentityAndBundle() throws Exception {
        var root=source();var id=UUID.randomUUID();String body=json.writeValueAsString(Map.of("id",id,"totalPeriodCount",90));
        mvc.perform(linked(post("/api/v1/sankalpas/"+root.id()+"/extensions")).header("Idempotency-Key",id)
                .contentType("application/json").content(body)).andExpect(status().isCreated())
                .andExpect(header().string("Location","/api/v1/sankalpas/"+id))
                .andExpect(header().exists("Sankalpa-Practice-Revision"))
                .andExpect(jsonPath("$.series.length()").value(2)).andExpect(jsonPath("$.sankalpa.extensionOf").value(root.id().toString()));
        mvc.perform(linked(post("/api/v1/sankalpas/"+root.id()+"/extensions")).header("Idempotency-Key",id)
                .contentType("application/json").content(body)).andExpect(status().isOk()).andExpect(jsonPath("$.created").value(false));
        mvc.perform(linked(post("/api/v1/sankalpas/"+root.id()+"/extensions")).header("Idempotency-Key",UUID.randomUUID())
                .contentType("application/json").content(body)).andExpect(status().isBadRequest());
    }
    @Test void concurrentExtensionsCannotBranch() throws Exception {
        var root=source();var start=new CyclicBarrier(2);var pool=Executors.newFixedThreadPool(2);
        try {
            Callable<Object> attempt=()->{start.await();try{return service.extend(root.id(),SankalpaId.newId(),90,LINKED);}catch(PracticeException e){return e;}};
            var a=pool.submit(attempt);var b=pool.submit(attempt);var results=List.of(a.get(10,TimeUnit.SECONDS),b.get(10,TimeUnit.SECONDS));
            assertThat(results.stream().filter(v->v instanceof ExtensionResult)).hasSize(1);
            assertThat(service.linkedSeries(root.id(),LINKED)).hasSize(2);
            assertThat(results.stream().filter(v->v instanceof PracticeException).map(v->((PracticeException)v).code()))
                    .containsExactly("EXTENSION_ALREADY_EXISTS");
        } finally {pool.shutdownNow();}
    }
    @Test void unrelatedMatchingPracticeDoesNotShare() {
        var root=source();log(root,clock.now);var other=source();var longer=child(root);
        assertThat(service.totalSessionCount(other.id())).isZero();assertThat(service.totalSessionCount(longer.id())).isEqualTo(1);
    }
    @Test void validationAcceptsDivergedHistoryAndRejectsCorruption() {
        var root=source();var longer=child(root);service.pause(root.id(),LINKED);
        var vows=service.linkedSeries(root.id(),LINKED);
        PracticeValidation.validate(vows,List.of());
        var corrupt=Sankalpa.reconstitute(longer.id(),new Title("Different"),longer.description(),longer.actionType(),longer.commitment(),
                longer.declaredAt(),longer.lifecycle(),0,longer.seriesId(),root.id());
        assertThatThrownBy(()->PracticeValidation.validate(List.of(service.detail(root.id(),LINKED),corrupt),List.of())).isInstanceOf(IllegalStateException.class);
    }
    @Test void pendingConversationConfirmationSurvivesUpgradeGateAndReplaysSafely() {
        var root = source();
        var thread = UUID.randomUUID();
        var proposal = proposals.proposeSession(thread, UUID.randomUUID(), root.id(),
                LocalDate.of(2026, 7, 20).atTime(8, 0), "Sat for 45 minutes", List.of());
        var longer = child(root);
        var confirmation = UUID.randomUUID();
        assertThatThrownBy(() -> proposals.confirm(thread, proposal.id(), confirmation))
                .isInstanceOf(PracticeException.class);
        assertThat(proposals.findPendingByThread(thread).id()).isEqualTo(proposal.id());
        var accepted = proposals.confirm(thread, proposal.id(), confirmation, LINKED);
        assertThat(accepted.replay()).isFalse();
        assertThat(service.totalSessionCount(root.id())).isEqualTo(1);
        assertThat(service.totalSessionCount(longer.id())).isEqualTo(1);
        long revision = service.readSnapshot(null, () -> true).revision();
        assertThat(proposals.confirm(thread, proposal.id(), confirmation).replay()).isTrue();
        assertThat(service.readSnapshot(null, () -> true).revision()).isEqualTo(revision);
    }

    @Test void extensionRejectsMalformedAndInheritedFieldsAndRevisionStaysExact() throws Exception {
        var root = source();
        String path = "/api/v1/sankalpas/" + root.id() + "/extensions";
        var id = UUID.randomUUID();
        mvc.perform(linked(post(path)).header("Idempotency-Key", id).contentType("application/json")
                .content("{\"id\":\"" + id + "\",\"totalPeriodCount\":90,\"title\":\"Changed\"}"))
                .andExpect(status().isBadRequest()).andExpect(jsonPath("$.code").value("INVALID_EXTENSION_REQUEST"));
        mvc.perform(linked(post(path)).header("Idempotency-Key", id).contentType("application/json")
                .content("{\"id\":\"" + id + "\",\"totalPeriodCount\":0}"))
                .andExpect(status().isBadRequest()).andExpect(jsonPath("$.code").value("INVALID_EXTENSION_REQUEST"));
        mvc.perform(linked(post(path)).header("Idempotency-Key", id).contentType("application/json")
                .content("{\"id\":\"" + id + "\",\"totalPeriodCount\":90.5}"))
                .andExpect(status().isBadRequest()).andExpect(jsonPath("$.code").value("INVALID_EXTENSION_REQUEST"));
        jdbc.update("UPDATE service_metadata SET metadata_value='9007199254740993' WHERE metadata_key='practice_revision'");
        mvc.perform(linked(get("/api/v1/sankalpas/" + root.id())))
                .andExpect(status().isOk()).andExpect(header().string("Sankalpa-Practice-Revision", "9007199254740993"));
        mvc.perform(linked(get("/api/v1/sessions")).param("cursor", "garbage"))
                .andExpect(status().isBadRequest()).andExpect(jsonPath("$.code").value("INVALID_SESSION_CURSOR"));
    }

    @Test void sameExtensionIdentityCannotClaimTwoUnrelatedRoots() throws Exception {
        var one = source();
        var two = source();
        var id = SankalpaId.newId();
        var start = new CyclicBarrier(2);
        var pool = Executors.newFixedThreadPool(2);
        try {
            java.util.function.Function<Sankalpa, Object> extend = root -> {
                try { start.await(5, TimeUnit.SECONDS); return service.extend(root.id(), id, 90, LINKED); }
                catch (PracticeException refusal) { return refusal; }
                catch (Exception failure) { throw new IllegalStateException(failure); }
            };
            var a = pool.submit(() -> extend.apply(one));
            var b = pool.submit(() -> extend.apply(two));
            var results = List.of(a.get(10, TimeUnit.SECONDS), b.get(10, TimeUnit.SECONDS));
            assertThat(results.stream().filter(ExtensionResult.class::isInstance)).hasSize(1);
            var refusal = (PracticeException) results.stream().filter(PracticeException.class::isInstance).findFirst().orElseThrow();
            assertThat(refusal.code()).isEqualTo("EXTENSION_IDENTITY_CONFLICT");
            assertThat(service.list(LINKED)).hasSize(3);
            PracticeValidation.validate(service.list(LINKED), service.cursorSessions(null, null, null, null, 100, LINKED).content());
        } finally { pool.shutdownNow(); }
    }

    @Test void publishedContractIncludesLinkedEndpointsAndExplicitHeaders() throws Exception {
        var document = json.readTree(mvc.perform(get("/v3/api-docs")).andExpect(status().isOk()).andReturn().getResponse().getContentAsString());
        var extension = document.path("paths").path("/api/v1/sankalpas/{id}/extensions").path("post");
        assertThat(extension.isMissingNode()).isFalse();
        assertThat(extension.path("parameters").toString()).contains("Linked-Sankalpa-Version", "Sankalpa-Service-Instance", "Idempotency-Key");
        assertThat(document.path("paths").has("/api/v1/sessions")).isTrue();
        assertThat(document.path("paths").has("/api/v1/sankalpas/{id}/linked-series")).isTrue();
        assertThat(document.path("components").path("schemas").path("SankalpaResponse").path("properties").has("totalSessionCount")).isTrue();
        mvc.perform(get("/api/v1/capabilities")).andExpect(status().isOk()).andExpect(jsonPath("$.linkedSankalpaExtensions").value(1));
    }

}
