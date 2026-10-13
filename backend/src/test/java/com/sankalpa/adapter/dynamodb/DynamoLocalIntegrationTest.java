package com.sankalpa.adapter.dynamodb;

import com.fasterxml.jackson.databind.*;
import com.sankalpa.adapter.out.dynamodb.*;
import com.sankalpa.adapter.config.*;
import com.sankalpa.application.*;
import com.sankalpa.application.conversation.*;
import com.sankalpa.application.port.SankalpaClock;
import com.sankalpa.domain.*;
import com.sankalpa.domain.commitment.*;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import software.amazon.awssdk.services.dynamodb.*;
import software.amazon.awssdk.services.dynamodb.model.*;
import software.amazon.awssdk.auth.credentials.*;
import software.amazon.awssdk.regions.Region;
import java.net.URI;
import java.time.*;
import java.util.*;
import java.util.concurrent.*;
import static org.assertj.core.api.Assertions.*;

@EnabledIfEnvironmentVariable(named="SANKALPA_TEST_DYNAMODB_ENDPOINT",matches="http://(127\\.0\\.0\\.1|localhost):[0-9]+")
class DynamoLocalIntegrationTest {
    DynamoDbClient client;
    String table;
    AwsDocumentStore store;
    DynamoUnitOfWork tx;
    DynamoRepository repo;
    SankalpaUseCases service;
    ConversationUseCases proposals;
    final LocalDateTime now=LocalDateTime.of(2026,10,13,12,0);
    final ObjectMapper json=new ObjectMapper().findAndRegisterModules().disable(SerializationFeature.WRITE_DATES_AS_TIMESTAMPS);
    @BeforeEach void setup() {
        client=DynamoDbClient.builder().region(Region.US_EAST_1).endpointOverride(URI.create(System.getenv("SANKALPA_TEST_DYNAMODB_ENDPOINT")))
                .credentialsProvider(StaticCredentialsProvider.create(AwsBasicCredentials.create("local","local"))).build();
        table="sankalpa-test-"+UUID.randomUUID().toString();
        client.createTable(CreateTableRequest.builder().tableName(table).billingMode(BillingMode.PAY_PER_REQUEST)
                .attributeDefinitions(AttributeDefinition.builder().attributeName("PK").attributeType(ScalarAttributeType.S).build(),AttributeDefinition.builder().attributeName("SK").attributeType(ScalarAttributeType.S).build())
                .keySchema(KeySchemaElement.builder().attributeName("PK").keyType(KeyType.HASH).build(),KeySchemaElement.builder().attributeName("SK").keyType(KeyType.RANGE).build()).build());
        store=new AwsDocumentStore(client,table,json);
        store.commit(List.of(new DocumentStore.Change("META",null,json.createObjectNode().put("schemaVersion",1).put("status","READY").put("serviceInstanceId",UUID.randomUUID().toString()).put("practiceRevision",0).put("commitSequence",0))));
        tx=new DynamoUnitOfWork(store);repo=new DynamoRepository(tx,json);
        var clock=new SankalpaClock(){public LocalDateTime now(){return now;} public LocalDate today(){return now.toLocalDate();}};
        var core=new SankalpaService(repo,repo,clock); service=new TransactionalSankalpaUseCases(core,tx);
        proposals=new TransactionalConversationUseCases(new ProposalService(repo,core,clock,Duration.ofMinutes(30)),tx);
    }
    @AfterEach void clean() { if(client!=null){ if(table!=null)client.deleteTable(DeleteTableRequest.builder().tableName(table).build());client.close();} }
    Sankalpa source(){var v=service.declare("坐禅","Sit",ActionType.MEDITATION,now.toLocalDate().minusDays(10),PeriodUnit.DAY,1,40); return service.begin(v.id(),now.minusDays(10));}
    @Test void realTransactionsReplayTombstonesAndColdAdapters() {
        var root=source(); var id=SessionId.newId(); service.logSession(root.id(),id,now.minusDays(1));
        service.logSession(root.id(),id,now.minusDays(1));
        var child=service.extend(root.id(),SankalpaId.newId(),90,PracticeContract.LINKED_V1).sankalpa();
        assertThat(service.totalSessionCount(child.id())).isEqualTo(1);
        service.deleteSession(root.id(),id,PracticeContract.LINKED_V1);
        assertThatThrownBy(()->service.logSession(root.id(),id,now.minusDays(1),PracticeContract.LINKED_V1)).isInstanceOf(SessionDeletedException.class);
        var coldTx=new DynamoUnitOfWork(new AwsDocumentStore(client,table,json)); var coldRepo=new DynamoRepository(coldTx,json);
        assertThat(coldTx.read(()->coldRepo.findAll())).hasSize(2); assertThat(store.query("JOURNAL#")).isEmpty();
        assertThat(coldTx.metadata().get("serviceInstanceId")).isEqualTo(tx.metadata().get("serviceInstanceId"));
    }
    @Test void parallelSDKClientsResolveIdentityContention() throws Exception {
        var root=source();var id=SessionId.newId();
        try(var executor=Executors.newFixedThreadPool(3)){
            var jobs=new ArrayList<Callable<Void>>();for(int i=0;i<6;i++)jobs.add(()->{service.logSession(root.id(),id,now.minusHours(1));return null;});
            for(var future:executor.invokeAll(jobs))future.get();
        }
        assertThat(service.totalSessionCount(root.id())).isEqualTo(1);
        assertThat(store.query("SESSION#")).hasSize(1);
    }
    @Test void atomicProposalAndLimitRefusal() {
        var root=source();var thread=UUID.randomUUID();var confirmation=UUID.randomUUID();
        var p=proposals.proposeSession(thread,UUID.randomUUID(),root.id(),now.minusHours(1),"Session",List.of());
        proposals.confirm(thread,p.id(),confirmation);assertThat(proposals.confirm(thread,p.id(),confirmation).replay()).isTrue();
        assertThat(service.totalSessionCount(root.id())).isEqualTo(1);
        var changes=new ArrayList<DocumentStore.Change>();for(int i=0;i<101;i++)changes.add(new DocumentStore.Change("TEST#"+i,null,json.createObjectNode().put("x",i)));
        assertThatThrownBy(()->store.commit(changes)).isInstanceOf(PracticeException.class);
        assertThat(store.query("TEST#")).isEmpty();
    }
}
