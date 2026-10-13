package com.sankalpa.adapter.out.dynamodb;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ObjectNode;
import com.sankalpa.application.PracticeException;
import software.amazon.awssdk.services.dynamodb.DynamoDbClient;
import software.amazon.awssdk.services.dynamodb.model.*;
import java.nio.charset.StandardCharsets;
import java.util.*;

public final class AwsDocumentStore implements DocumentStore {
    public static final String PARTITION = "PRACTICE#default";
    private final DynamoDbClient client;
    private final String table;
    private final ObjectMapper json;
    public AwsDocumentStore(DynamoDbClient client, String table, ObjectMapper json) {
        this.client = client; this.table = table; this.json = json;
    }
    private Map<String, AttributeValue> key(String key) {
        return Map.of("PK", text(PARTITION), "SK", text(key));
    }
    private static AttributeValue text(String value) { return AttributeValue.builder().s(value).build(); }
    private ObjectNode decode(Map<String, AttributeValue> item) {
        if (item == null || item.isEmpty()) return null;
        try { return (ObjectNode) json.readTree(item.get("payload").s()); }
        catch (Exception failure) { throw new IllegalStateException("Invalid persisted document"); }
    }
    public ObjectNode get(String key) {
        return decode(client.getItem(GetItemRequest.builder().tableName(table).key(key(key)).consistentRead(true).build()).item());
    }
    public Map<String, ObjectNode> query(String prefix) {
        Map<String, ObjectNode> results = new TreeMap<>();
        Map<String, AttributeValue> cursor = null;
        do {
            var page = client.query(QueryRequest.builder().tableName(table).consistentRead(true)
                    .keyConditionExpression("PK = :pk AND begins_with(SK, :prefix)")
                    .expressionAttributeValues(Map.of(":pk", text(PARTITION), ":prefix", text(prefix)))
                    .exclusiveStartKey(cursor).build());
            page.items().forEach(item -> results.put(item.get("SK").s(), decode(item)));
            cursor = page.lastEvaluatedKey();
        } while (cursor != null && !cursor.isEmpty());
        return results;
    }
    public void commit(List<Change> changes) {
        if (changes.isEmpty()) return;
        if (changes.size() > 100 || changes.stream().map(Change::key).distinct().count() != changes.size())
            throw new PracticeException("PERSISTENCE_LIMIT_REACHED", "Atomic operation exceeds database limits");
        List<TransactWriteItem> actions = new ArrayList<>();
        long bytes = 0;
        for (var change : changes) {
            String condition = change.before() == null ? "attribute_not_exists(PK)" : "payload = :before";
            Map<String, AttributeValue> values = change.before() == null ? null : Map.of(":before", text(change.before().toString()));
            if (change.checkOnly()) {
                actions.add(TransactWriteItem.builder().conditionCheck(ConditionCheck.builder().tableName(table)
                        .key(key(change.key())).conditionExpression(condition).expressionAttributeValues(values).build()).build());
            } else if (change.after() == null) {
                actions.add(TransactWriteItem.builder().delete(Delete.builder().tableName(table).key(key(change.key()))
                        .conditionExpression(condition).expressionAttributeValues(values).build()).build());
            } else {
                String payload = change.after().toString();
                long size = payload.getBytes(StandardCharsets.UTF_8).length + change.key().getBytes(StandardCharsets.UTF_8).length + 128;
                if (size > 400 * 1024) throw new PracticeException("PERSISTENCE_LIMIT_REACHED", "Record exceeds database limits");
                bytes += size;
                Map<String, AttributeValue> item = new HashMap<>(key(change.key()));
                item.put("payload", text(payload));
                if (change.after().has("ttlEpoch")) item.put("ttlEpoch", AttributeValue.builder().n(change.after().get("ttlEpoch").asText()).build());
                actions.add(TransactWriteItem.builder().put(Put.builder().tableName(table).item(item)
                        .conditionExpression(condition).expressionAttributeValues(values).build()).build());
            }
        }
        if (bytes > 4 * 1024 * 1024) throw new PracticeException("PERSISTENCE_LIMIT_REACHED", "Atomic operation exceeds database limits");
        var request = TransactWriteItemsRequest.builder().transactItems(actions).clientRequestToken(UUID.randomUUID().toString()).build();
        // SDK retries send this exact request/token. Never rerun domain code on an ambiguous network outcome.
        try { client.transactWriteItems(request); }
        catch (TransactionCanceledException failure) {
            if (!failure.cancellationReasons().isEmpty() && failure.cancellationReasons().stream()
                    .allMatch(r -> r.code() == null || Set.of("None", "ConditionalCheckFailed", "TransactionConflict").contains(r.code())))
                throw new Conflict();
            throw failure;
        }
    }
}
