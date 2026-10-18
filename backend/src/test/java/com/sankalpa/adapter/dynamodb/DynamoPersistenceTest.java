package com.sankalpa.adapter.dynamodb;

import com.fasterxml.jackson.databind.*;
import com.fasterxml.jackson.databind.node.ObjectNode;
import com.sankalpa.adapter.out.dynamodb.*;
import com.sankalpa.adapter.config.*;
import com.sankalpa.application.*;
import com.sankalpa.application.conversation.*;
import com.sankalpa.application.port.SankalpaClock;
import com.sankalpa.domain.*;
import com.sankalpa.domain.commitment.*;
import org.junit.jupiter.api.*;
import java.time.*;
import java.util.*;
import java.util.concurrent.*;
import static org.assertj.core.api.Assertions.*;

class DynamoPersistenceTest {
    static class MemoryStore implements DocumentStore {
        final Map<String, ObjectNode> data = new TreeMap<>();
        Runnable queryHook;
        List<Change> lastCommit = List.of();
        boolean loseCommitResponse;
        boolean conflictOnce;
        synchronized public ObjectNode get(String key) { var n = data.get(key); return n == null ? null : n.deepCopy(); }
        synchronized public Map<String, ObjectNode> query(String prefix) {
            Map<String, ObjectNode> result = new TreeMap<>(); data.forEach((k,v) -> { if (k.startsWith(prefix)) result.put(k, v.deepCopy()); });
            if (queryHook != null) { var hook = queryHook; queryHook = null; hook.run(); } return result;
        }
        synchronized public void commit(List<Change> changes) {
            if (conflictOnce) { conflictOnce = false; throw new Conflict(); }
            if (changes.size() > 100) throw new AssertionError("Transaction action overflow");
            lastCommit = List.copyOf(changes);
            if (changes.stream().map(Change::key).distinct().count() != changes.size()) throw new AssertionError("Duplicate transaction keys");
            for (var c : changes) if (!Objects.equals(data.get(c.key()), c.before())) throw new Conflict();
            for (var c : changes) if (!c.checkOnly()) { if (c.after() == null) data.remove(c.key()); else data.put(c.key(), c.after().deepCopy()); }
            if (loseCommitResponse) { loseCommitResponse = false; throw new PracticeException("INDETERMINATE", "Lost response after commit"); }
        }
    }
    final ObjectMapper json = new ObjectMapper().findAndRegisterModules().disable(SerializationFeature.WRITE_DATES_AS_TIMESTAMPS);
    MemoryStore store;
    DynamoUnitOfWork tx;
    DynamoRepository repo;
    SankalpaUseCases service;
    ConversationUseCases proposals;
    final LocalDateTime now = LocalDateTime.of(2026,10,13,12,0);
    @BeforeEach void setup() {
        store = new MemoryStore();
        store.data.put("META", json.createObjectNode().put("status","READY").put("schemaVersion",1).put("serviceInstanceId",UUID.randomUUID().toString()).put("practiceRevision",0).put("commitSequence",0));
        tx = new DynamoUnitOfWork(store); repo = new DynamoRepository(tx,json);
        var clock = new SankalpaClock() { public LocalDateTime now(){return now;} public LocalDate today(){return now.toLocalDate();} };
        var core = new SankalpaService(repo,repo,clock); service = new TransactionalSankalpaUseCases(core,tx);
        proposals = new TransactionalConversationUseCases(new ProposalService(repo,core,clock,Duration.ofMinutes(30)),tx);
    }
    Sankalpa source() { var v = service.declare("Sit","Practice",ActionType.MEDITATION,now.toLocalDate().minusDays(10),PeriodUnit.DAY,1,40); return service.begin(v.id(),now.minusDays(10)); }
    BatchSessionPlan batchPlan() {
        return new BatchSessionPlan(BatchSessionPlan.Mode.DAILY_RANGE, now.toLocalDate().minusDays(30),
                now.toLocalDate().minusDays(1), LocalTime.of(8,0), null);
    }
    Sankalpa batchTarget() {
        var v=service.declare("Observe","",ActionType.OBSERVANCE,now.toLocalDate().minusDays(40),PeriodUnit.DAY,1,100);
        return service.begin(v.id(),now.minusDays(40),PracticeContract.LINKED_V1);
    }
    @Test void thirtySessionConfirmationUsesNinetyFiveActionsIncludingFenceAndReplaysLostResponse() {
        var v=batchTarget(); var thread=UUID.randomUUID();
        var p=proposals.proposeSessions(thread,UUID.randomUUID(),v.id(),batchPlan(),PracticeContract.LINKED_V1);
        var fence=json.createObjectNode().put("leaseUntil",java.time.Instant.now().getEpochSecond()+120);
        store.data.put("LEASE#test",fence);tx.bindFence(new DocumentStore.Change("LEASE#test",fence,null,true));
        var confirmation=UUID.randomUUID();store.loseCommitResponse=true;
        assertThatThrownBy(()->proposals.confirm(thread,p.id(),confirmation,PracticeContract.LINKED_V1,true)).isInstanceOf(PracticeException.class);
        assertThat(store.lastCommit).hasSize(95);
        assertThat(store.lastCommit.stream().filter(DocumentStore.Change::checkOnly).count()).isEqualTo(1);
        assertThat(store.lastCommit.stream().filter(c->c.key().startsWith("SESSION#")).count()).isEqualTo(30);
        assertThat(store.lastCommit.stream().filter(c->c.after()!=null).mapToLong(c->c.after().toString().getBytes(java.nio.charset.StandardCharsets.UTF_8).length).sum()).isLessThan(4*1024*1024);
        tx.clearFence();
        var replay=proposals.confirm(thread,p.id(),confirmation,PracticeContract.LINKED_V1,true);
        assertThat(replay.replay()).isTrue();assertThat(replay.proposal().batchResult().sessionIds()).hasSize(30);
        assertThat(service.totalSessionCount(v.id())).isEqualTo(30);
        // Read through a fresh codec/unit of work: this is persisted identity, not an object cache.
        var other=new DynamoUnitOfWork(store); var decoded=new DynamoRepository(other,json);
        assertThat(other.read(()->decoded.findByIdForUpdate(p.id())).orElseThrow()).isEqualTo(replay.proposal());
    }
    @Test void batchDomainRefusalRollsBackEveryStagedDocumentAndRevision() {
        var v=batchTarget();var p=proposals.proposeSessions(UUID.randomUUID(),UUID.randomUUID(),v.id(),batchPlan(),PracticeContract.LINKED_V1);
        long revision=tx.read(repo::readRevision); int[] calls={0};
        var core=new SankalpaService(repo,repo,new SankalpaClock(){public LocalDateTime now(){return now;}public LocalDate today(){return now.toLocalDate();}});
        var failing=(SankalpaUseCases)java.lang.reflect.Proxy.newProxyInstance(getClass().getClassLoader(),new Class<?>[]{SankalpaUseCases.class},(proxy,method,args)->{
            if(method.getName().equals("logSession") && ++calls[0]==17) throw new DomainException("TEST_REFUSAL","Injected");
            try{return method.invoke(core,args);}catch(java.lang.reflect.InvocationTargetException failure){throw failure.getCause();}
        });
        var clock=new SankalpaClock(){public LocalDateTime now(){return now;}public LocalDate today(){return now.toLocalDate();}};
        var failingProposals=new TransactionalConversationUseCases(new ProposalService(repo,failing,clock,Duration.ofMinutes(30)),tx);
        var result=failingProposals.confirm(p.threadId(),p.id(),UUID.randomUUID(),PracticeContract.LINKED_V1,true);
        assertThat(result.proposal().status()).isEqualTo(Proposal.Status.REJECTED);assertThat(calls[0]).isEqualTo(17);
        assertThat(store.query("SESSION#")).isEmpty();assertThat(store.query("OWNER#")).isEmpty();assertThat(store.query("JOURNAL#")).isEmpty();
        assertThat(tx.read(repo::readRevision)).isEqualTo(revision);
    }
    @Test void batchContentionRetriesTheSameIdentitiesAndExpiredLeaseCommitsNothing() {
        var v=batchTarget();var p=proposals.proposeSessions(UUID.randomUUID(),UUID.randomUUID(),v.id(),batchPlan(),PracticeContract.LINKED_V1);
        var fence=json.createObjectNode().put("leaseUntil",0);store.data.put("LEASE#test",fence);
        tx.bindFence(new DocumentStore.Change("LEASE#test",fence,null,true));
        assertThatThrownBy(()->proposals.confirm(p.threadId(),p.id(),UUID.randomUUID(),PracticeContract.LINKED_V1,true)).isInstanceOf(ConversationFailure.class);
        assertThat(store.query("SESSION#")).isEmpty();tx.clearFence();store.conflictOnce=true;
        var result=proposals.confirm(p.threadId(),p.id(),UUID.randomUUID(),PracticeContract.LINKED_V1,true);
        assertThat(result.proposal().status()).isEqualTo(Proposal.Status.EXECUTED);
        assertThat(service.totalSessionCount(v.id())).isEqualTo(30);
    }
    @Test void linkedFactsTombstonesAndRevisionSurviveNewAdapters() {
        var root = source(); var id = SessionId.newId();
        service.logSession(root.id(),id,now.minusDays(1));
        long revision = tx.read(repo::readRevision);
        service.logSession(root.id(),id,now.minusDays(1)); assertThat(tx.read(repo::readRevision)).isEqualTo(revision);
        var child = service.extend(root.id(),SankalpaId.newId(),90,PracticeContract.LINKED_V1).sankalpa();
        assertThat(service.totalSessionCount(child.id())).isEqualTo(1);
        service.deleteSession(root.id(),id,PracticeContract.LINKED_V1);
        assertThat(service.totalSessionCount(child.id())).isZero();
        var anotherTx = new DynamoUnitOfWork(store);
        var another = new DynamoRepository(anotherTx,json);
        assertThatThrownBy(() -> service.logSession(root.id(),id,now.minusDays(1),PracticeContract.LINKED_V1)).isInstanceOf(SessionDeletedException.class);
        assertThat(store.query("JOURNAL#")).isEmpty();
        assertThat(anotherTx.read(() -> another.findIdentity(id)).orElseThrow().state()).isEqualTo(SessionIdentityState.DELETED);
    }
    @Test void concurrentReplayAndExtensionsCreateOneIdentity() throws Exception {
        var root=source(); var session=SessionId.newId(); var extension=SankalpaId.newId();
        try (var executor=Executors.newFixedThreadPool(4)) {
            var jobs=new ArrayList<Callable<Void>>();
            for(int i=0;i<12;i++) jobs.add(() -> { service.logSession(root.id(),session,now.minusDays(1),PracticeContract.LINKED_V1); service.extend(root.id(),extension,90,PracticeContract.LINKED_V1); return null; });
            for(var future:executor.invokeAll(jobs)) future.get();
        }
        assertThat(service.linkedSeries(root.id(),PracticeContract.LINKED_V1)).hasSize(2);
        assertThat(service.totalSessionCount(extension)).isEqualTo(1);
        assertThat(store.query("SESSION#")).hasSize(1);
    }
    @Test void confirmationIsAtomicAndReplaySafe() {
        var root=source(); UUID thread=UUID.randomUUID(),run=UUID.randomUUID(),confirmation=UUID.randomUUID();
        var proposal=proposals.proposeSession(thread,run,root.id(),now.minusHours(1),"A session",List.of());
        assertThat(proposals.confirm(thread,proposal.id(),confirmation).proposal().status()).isEqualTo(Proposal.Status.EXECUTED);
        assertThat(proposals.confirm(thread,proposal.id(),confirmation).replay()).isTrue();
        assertThat(service.totalSessionCount(root.id())).isEqualTo(1);
        assertThat(store.query("THREAD#")).isEmpty();
    }
    @Test void failedTransactionDiscardsAllChangesAndChangedReadsRestart() {
        var root=source(); int before=store.data.size();
        assertThatThrownBy(() -> tx.write(() -> { repo.incrementRevision(); repo.claimIdentity(new SessionIdentity(SessionId.newId(),root.id(),SessionIdentityState.ACTIVE)); throw new IllegalArgumentException("Refuse"); })).isInstanceOf(IllegalArgumentException.class);
        assertThat(store.data).hasSize(before);
        long revision=tx.read(repo::readRevision);
        store.queryHook=() -> { var m=store.data.get("META").deepCopy(); m.put("practiceRevision",revision+1).put("commitSequence",m.get("commitSequence").asLong()+1); store.data.put("META",m); };
        assertThatThrownBy(() -> service.readSnapshot(revision,service::list)).isInstanceOf(PracticeException.class).extracting("code").isEqualTo("READ_SNAPSHOT_CHANGED");
    }
    @Test void missingAndImportingMetadataFailClosed() {
        store.data.get("META").put("status","IMPORTING"); assertThatThrownBy(tx::metadata).isInstanceOf(IllegalStateException.class);
        store.data.clear(); assertThatThrownBy(tx::metadata).isInstanceOf(IllegalStateException.class);
    }
    @Test void dailyQuotaStillAllowsConfirmationAndLeaseFencesMutations() {
        var guard=new DynamoConversationGuard(store,tx,json,1,1);
        UUID thread=UUID.randomUUID(),run=UUID.randomUUID();
        var input=new ConversationCoordinator.RunInput(thread,run,List.of(),List.of(),null);
        guard.run(input,() -> { guard.beforeModel(); assertThatThrownBy(() -> guard.run(input,() -> { guard.beforeModel(); return null; })).isInstanceOf(ConversationFailure.class); return null; });
        assertThatThrownBy(() -> guard.run(input,() -> { guard.beforeModel(); return null; })).isInstanceOf(ConversationFailure.class);
        var resume=new ConversationCoordinator.RunInput(thread,UUID.randomUUID(),List.of(),List.of(),new ConversationCoordinator.Resume(UUID.randomUUID(),true,null));
        guard.run(resume,() -> null);
        assertThat(store.query("LEASE#")).isEmpty();
    }
    @Test void expiredOwnerCannotCommitOrReleaseNewLease() {
        var guard=new DynamoConversationGuard(store,tx,json,20,20);
        UUID thread=UUID.randomUUID(); String key="LEASE#THREAD#"+thread;
        var input=new ConversationCoordinator.RunInput(thread,UUID.randomUUID(),List.of(),List.of(),null);
        guard.run(input,()->{
            var replacement=store.get(key);replacement.put("token","new-owner");store.data.put(key,replacement);
            assertThatThrownBy(this::source).isInstanceOf(ConversationFailure.class);
            return null;
        });
        assertThat(store.query("VOW#")).isEmpty();
        assertThat(store.get(key).path("token").asText()).isEqualTo("new-owner");
    }
    @Test void rejectedConfirmationDoesNotLeavePracticeEffects() {
        var root=source();UUID thread=UUID.randomUUID();
        var p=proposals.proposeSession(thread,UUID.randomUUID(),root.id(),now.minusHours(1),"Session",List.of());
        // Simulate a pending proposal becoming invalid before confirmation.
        var stored=store.data.get("PROPOSAL#"+p.id()).deepCopy();
        ((ObjectNode)stored.get("payload")).put("occurredAt",now.plusHours(1).toString());store.data.put("PROPOSAL#"+p.id(),stored);
        long revision=tx.read(repo::readRevision);
        var result=proposals.confirm(thread,p.id(),UUID.randomUUID());
        assertThat(result.proposal().status()).isEqualTo(Proposal.Status.REJECTED);
        assertThat(store.query("SESSION#")).isEmpty();assertThat(tx.read(repo::readRevision)).isEqualTo(revision);
    }
}
