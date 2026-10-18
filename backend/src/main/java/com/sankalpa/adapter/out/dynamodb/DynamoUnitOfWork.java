package com.sankalpa.adapter.out.dynamodb;

import com.fasterxml.jackson.databind.node.ObjectNode;
import com.sankalpa.adapter.config.UseCaseTransactions;
import com.sankalpa.application.PracticeException;
import java.util.*;
import java.util.function.Supplier;

/** Optimistic snapshot boundary. The META comparison covers every business writer. */
public final class DynamoUnitOfWork implements UseCaseTransactions {
    private final DocumentStore store;
    private final boolean allowImporting;
    private final ThreadLocal<Attempt> current = new ThreadLocal<>();
    private final ThreadLocal<DocumentStore.Change> fence = new ThreadLocal<>();
    private static final class Attempt {
        final ObjectNode metadata;
        final Map<String, ObjectNode> reads = new HashMap<>();
        final Map<String, ObjectNode> writes = new LinkedHashMap<>();
        final boolean writable;
        Attempt(ObjectNode metadata, boolean writable) { this.metadata = metadata; this.writable = writable; reads.put("META", metadata.deepCopy()); }
    }
    public DynamoUnitOfWork(DocumentStore store) { this(store, false); }
    public DynamoUnitOfWork(DocumentStore store, boolean allowImporting) { this.store = store; this.allowImporting = allowImporting; }
    public ObjectNode metadata() {
        var value = store.get("META");
        if (value == null || !("READY".equals(value.path("status").asText()) || (allowImporting && "IMPORTING".equals(value.path("status").asText()))) || !value.path("schemaVersion").isInt() || value.path("schemaVersion").asInt() != 1
                || !value.has("serviceInstanceId") || !value.path("practiceRevision").isIntegralNumber() || !value.path("practiceRevision").canConvertToLong() || value.path("practiceRevision").asLong(-1) < 0
                || !value.path("commitSequence").isIntegralNumber() || !value.path("commitSequence").canConvertToLong() || value.path("commitSequence").asLong(-1) < 0) throw new IllegalStateException("Database is not initialized with a supported READY schema");
        UUID.fromString(value.get("serviceInstanceId").asText());
        return value;
    }
    public void bindFence(DocumentStore.Change value) { fence.set(value); }
    public void clearFence() { fence.remove(); }
    public ObjectNode get(String key) {
        var tx = current.get();
        if (tx == null) throw new IllegalStateException("Persistence access requires a unit of work");
        if (tx.writes.containsKey(key)) return copy(tx.writes.get(key));
        if (!tx.reads.containsKey(key)) tx.reads.put(key, store.get(key));
        return copy(tx.reads.get(key));
    }
    public Map<String, ObjectNode> query(String prefix) {
        var tx = current.get();
        if (tx == null) throw new IllegalStateException("Persistence access requires a unit of work");
        Map<String, ObjectNode> records = new TreeMap<>(store.query(prefix));
        records.forEach((key, value) -> tx.reads.putIfAbsent(key, value.deepCopy()));
        tx.writes.forEach((key, value) -> { if (key.startsWith(prefix)) { if (value == null) records.remove(key); else records.put(key, value.deepCopy()); } });
        return records;
    }
    public void put(String key, ObjectNode value) { stage(key, value); }
    public void delete(String key) { stage(key, null); }
    private void stage(String key, ObjectNode value) {
        var tx = current.get();
        if (tx == null || !tx.writable) throw new IllegalStateException("Write outside a writable unit of work");
        get(key); tx.writes.put(key, copy(value));
    }
    private static ObjectNode copy(ObjectNode node) { return node == null ? null : node.deepCopy(); }
    public <T> T read(Supplier<T> action) { return execute(action, false); }
    public <T> T write(Supplier<T> action) { return execute(action, true); }
    private <T> T execute(Supplier<T> action, boolean writable) {
        if (current.get() != null) return action.get();
        for (int retry = 0; retry < 8; retry++) {
            var tx = new Attempt(metadata(), writable); current.set(tx);
            try {
                T result;
                try { result = action.get(); }
                catch (RuntimeException failure) {
                    // An invalidated read can otherwise misreport a transient missing record as a domain refusal.
                    if (!store.get("META").equals(tx.metadata)) throw new DocumentStore.Conflict();
                    throw failure;
                }
                if (tx.writes.isEmpty()) {
                    if (!store.get("META").equals(tx.metadata)) throw new DocumentStore.Conflict();
                } else {
                    ObjectNode meta = tx.writes.getOrDefault("META", tx.metadata.deepCopy());
                    meta.put("commitSequence", Math.addExact(tx.metadata.get("commitSequence").asLong(), 1));
                    tx.writes.put("META", meta);
                    List<DocumentStore.Change> changes = new ArrayList<>();
                    tx.writes.forEach((key, value) -> changes.add(new DocumentStore.Change(key, tx.reads.get(key), value)));
                    if (fence.get() != null) {
                        if (fence.get().before().path("leaseUntil").asLong() <= java.time.Instant.now().getEpochSecond())
                            throw new com.sankalpa.application.conversation.ConversationFailure("ASSISTANT_BUSY", "Assistant run lease expired");
                        changes.add(fence.get());
                    }
                    store.commit(changes);
                }
                return result;
            } catch (DocumentStore.Conflict contention) {
                if (fence.get() != null && !java.util.Objects.equals(store.get(fence.get().key()), fence.get().before()))
                    throw new com.sankalpa.application.conversation.ConversationFailure("ASSISTANT_BUSY", "Assistant run ownership changed");
                if (retry == 7) throw new PracticeException("PRACTICE_WRITE_CONTENDED", "Practice is busy; retry this same action");
                try { Thread.sleep(5L * (retry + 1)); }
                catch (InterruptedException interrupted) { Thread.currentThread().interrupt(); throw new PracticeException("PRACTICE_WRITE_CONTENDED", "Practice action interrupted"); }
            } finally { current.remove(); }
        }
        throw new AssertionError();
    }
}
