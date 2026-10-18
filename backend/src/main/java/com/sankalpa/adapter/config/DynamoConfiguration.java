package com.sankalpa.adapter.config;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.sankalpa.adapter.out.dynamodb.*;
import org.springframework.context.annotation.*;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.beans.factory.annotation.Value;
import software.amazon.awssdk.services.dynamodb.DynamoDbClient;
import software.amazon.awssdk.auth.credentials.*;
import software.amazon.awssdk.regions.Region;
import java.net.URI;
import java.time.Duration;

@Configuration
@ConditionalOnProperty(name="sankalpa.persistence", havingValue="dynamodb")
public class DynamoConfiguration {
    @Bean DynamoDbClient dynamoClient(@Value("${sankalpa.dynamodb.region:us-east-1}") String region,
            @Value("${sankalpa.dynamodb.endpoint:}") String endpoint, @Value("${sankalpa.deployment:local}") String deployment) {
        var builder = DynamoDbClient.builder().region(Region.of(region))
                .overrideConfiguration(c -> c.apiCallTimeout(Duration.ofSeconds(15)).apiCallAttemptTimeout(Duration.ofSeconds(5)));
        if (!endpoint.isBlank()) {
            URI uri = URI.create(endpoint);
            if (!"local".equals(deployment) || !java.util.Set.of("localhost", "127.0.0.1", "dynamodb").contains(uri.getHost()))
                throw new IllegalArgumentException("Database endpoint overrides are local-only");
            builder.endpointOverride(uri).credentialsProvider(StaticCredentialsProvider.create(AwsBasicCredentials.create("local", "local")));
        }
        return builder.build();
    }
    @Bean DocumentStore documentStore(DynamoDbClient client, @Value("${sankalpa.dynamodb.table}") String table, ObjectMapper json) {
        return new AwsDocumentStore(client, table, json);
    }
    @Bean DynamoUnitOfWork dynamoTransactions(DocumentStore store) { return new DynamoUnitOfWork(store); }
    @Bean com.sankalpa.application.conversation.ConversationRunGuard conversationRunGuard(DocumentStore store, DynamoUnitOfWork tx,
            ObjectMapper json, @Value("${sankalpa.assistant.runs-per-minute:30}") int minute,
            @Value("${sankalpa.assistant.runs-per-day:20}") int day) {
        return new DynamoConversationGuard(store, tx, json, minute, day);
    }
    @Bean DynamoRepository dynamoRepository(DynamoUnitOfWork tx, ObjectMapper json) { return new DynamoRepository(tx, json); }
}
