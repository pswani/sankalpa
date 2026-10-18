package com.sankalpa.adapter.out.dynamodb;

import com.fasterxml.jackson.databind.*;
import com.sankalpa.application.PracticeValidation;
import software.amazon.awssdk.services.dynamodb.DynamoDbClient;
import software.amazon.awssdk.auth.credentials.*;
import software.amazon.awssdk.regions.Region;
import java.net.URI;

/** Offline operator entry point: reuse the authoritative cross-record domain validator. */
public final class DatabaseVerifier {
    private DatabaseVerifier() {}
    public static void main(String[] args) {
        if (args.length != 3) throw new IllegalArgumentException("Expected table, region, local endpoint or '-' ");
        var builder = DynamoDbClient.builder().region(Region.of(args[1]));
        if (!args[2].equals("-")) {
            URI uri = URI.create(args[2]);
            if (!java.util.Set.of("127.0.0.1", "localhost").contains(uri.getHost())) throw new IllegalArgumentException("Verifier endpoint must be local");
            builder.endpointOverride(uri).credentialsProvider(StaticCredentialsProvider.create(AwsBasicCredentials.create("local","local")));
        }
        try (var client = builder.build()) {
            var json = new ObjectMapper().findAndRegisterModules().disable(SerializationFeature.WRITE_DATES_AS_TIMESTAMPS);
            verify(new AwsDocumentStore(client, args[0], json), json);
            System.out.println("Domain practice and linked-history validation passed");
        }
    }
    public static void verify(DocumentStore store, ObjectMapper json) {
        var tx = new DynamoUnitOfWork(store, true);
        var repo = new DynamoRepository(tx, json);
        tx.read(() -> {
            var vows = repo.findAll();
            PracticeValidation.validate(vows, repo.scanCandidates(vows.stream().map(v -> v.id()).toList(), null, null, null, Integer.MAX_VALUE));
            return null;
        });
    }
}
