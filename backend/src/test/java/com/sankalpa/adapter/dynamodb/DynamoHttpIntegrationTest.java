package com.sankalpa.adapter.dynamodb;

import com.fasterxml.jackson.databind.*;
import com.sankalpa.adapter.out.dynamodb.*;
import com.sankalpa.adapter.out.llm.ScriptedConversationModel;
import com.sankalpa.application.conversation.ConversationModel;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.web.servlet.MockMvc;
import software.amazon.awssdk.services.dynamodb.*;
import software.amazon.awssdk.services.dynamodb.model.*;
import software.amazon.awssdk.auth.credentials.*;
import software.amazon.awssdk.regions.Region;
import java.net.URI;
import java.util.*;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.*;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.*;
import static org.assertj.core.api.Assertions.*;

@EnabledIfEnvironmentVariable(named="SANKALPA_TEST_DYNAMODB_ENDPOINT",matches="http://(127\\.0\\.0\\.1|localhost):[0-9]+")
@SpringBootTest(properties={"spring.profiles.include=dynamodb","sankalpa.persistence=dynamodb","sankalpa.timezone=America/Chicago",
    "sankalpa.deployment=local","sankalpa.assistant.api-token=integration-test-token","sankalpa.assistant.enabled=true","sankalpa.assistant.provider=fake"})
@AutoConfigureMockMvc
class DynamoHttpIntegrationTest {
    static DynamoDbClient client;
    static String table="sankalpa-test-http-"+UUID.randomUUID();
    @Autowired MockMvc mvc;
    @Autowired ScriptedConversationModel model;
    @DynamicPropertySource static void initialize(DynamicPropertyRegistry properties) {
        client=DynamoDbClient.builder().region(Region.US_EAST_1).endpointOverride(URI.create(System.getenv("SANKALPA_TEST_DYNAMODB_ENDPOINT")))
            .credentialsProvider(StaticCredentialsProvider.create(AwsBasicCredentials.create("local","local"))).build();
        client.createTable(CreateTableRequest.builder().tableName(table).billingMode(BillingMode.PAY_PER_REQUEST)
            .attributeDefinitions(AttributeDefinition.builder().attributeName("PK").attributeType(ScalarAttributeType.S).build(),AttributeDefinition.builder().attributeName("SK").attributeType(ScalarAttributeType.S).build())
            .keySchema(KeySchemaElement.builder().attributeName("PK").keyType(KeyType.HASH).build(),KeySchemaElement.builder().attributeName("SK").keyType(KeyType.RANGE).build()).build());
        var json=new ObjectMapper(); new AwsDocumentStore(client,table,json).commit(List.of(new DocumentStore.Change("META",null,
            json.createObjectNode().put("schemaVersion",1).put("status","READY").put("serviceInstanceId",UUID.randomUUID().toString()).put("practiceRevision",0).put("commitSequence",0))));
        properties.add("sankalpa.dynamodb.table",()->table);
        properties.add("sankalpa.dynamodb.endpoint",()->System.getenv("SANKALPA_TEST_DYNAMODB_ENDPOINT"));
    }
    @AfterAll static void cleanup(){if(client!=null){client.deleteTable(DeleteTableRequest.builder().tableName(table).build());client.close();}}
    @Test void contextUsesDynamoAndAuthenticates() throws Exception {
        mvc.perform(get("/health/ready")).andExpect(status().isOk());
        mvc.perform(get("/api/v1/capabilities")).andExpect(status().isUnauthorized());
        mvc.perform(get("/api/v1/capabilities").header("Authorization","Bearer integration-test-token"))
            .andExpect(status().isOk()).andExpect(jsonPath("$.assistant.enabled").value(true));
    }
    @Test void sseUsesDurableRunGuard() throws Exception {
        model.enqueue(new ConversationModel.TextTurn("Ready to practice."));
        String body="""
            {"threadId":"%s","runId":"%s","state":{},"messages":[{"id":"%s","role":"user","content":"Hello"}],"tools":[],"context":[],"forwardedProps":{}}
            """.formatted(UUID.randomUUID(),UUID.randomUUID(),UUID.randomUUID());
        var result=mvc.perform(post("/api/v1/assistant/runs").header("Authorization","Bearer integration-test-token")
            .contentType("application/json").accept("text/event-stream").content(body)).andExpect(request().asyncStarted()).andReturn();
        var completed=mvc.perform(asyncDispatch(result)).andExpect(status().isOk()).andReturn();
        assertThat(completed.getResponse().getContentAsString()).contains("RUN_STARTED","Ready to practice.","RUN_FINISHED");
        assertThat(new AwsDocumentStore(client,table,new ObjectMapper()).query("LEASE#")).isEmpty();
    }
}
