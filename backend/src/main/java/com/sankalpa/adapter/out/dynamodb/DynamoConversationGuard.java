package com.sankalpa.adapter.out.dynamodb;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ObjectNode;
import com.sankalpa.application.conversation.*;
import java.time.Instant;
import java.util.*;
import java.util.function.Supplier;

public final class DynamoConversationGuard implements ConversationRunGuard {
    private final DocumentStore store;
    private final DynamoUnitOfWork tx;
    private final ObjectMapper json;
    private final int minuteLimit, dayLimit;
    private final ThreadLocal<Boolean> charged = new ThreadLocal<>();
    public DynamoConversationGuard(DocumentStore store, DynamoUnitOfWork tx, ObjectMapper json, int minuteLimit, int dayLimit) {
        this.store = store; this.tx = tx; this.json = json; this.minuteLimit = minuteLimit; this.dayLimit = dayLimit;
        if (minuteLimit < 1 || dayLimit < 1) throw new IllegalArgumentException("Assistant limits must be positive");
    }
    public <T> T run(ConversationCoordinator.RunInput input, Supplier<T> action) {
        String key = "LEASE#THREAD#" + input.threadId();
        ObjectNode lease = null;
        for (int attempt = 0; attempt < 8; attempt++) {
            long now = Instant.now().getEpochSecond(); var old = store.get(key);
            if (old != null && old.path("leaseUntil").asLong() > now) throw new ConversationFailure("ASSISTANT_BUSY", "Another run is active for this conversation");
            var next = json.createObjectNode().put("token", UUID.randomUUID().toString()).put("leaseUntil", now + 120).put("ttlEpoch", now + 3600);
            var changes = new ArrayList<DocumentStore.Change>(); changes.add(new DocumentStore.Change(key, old, next));
            try { store.commit(changes); lease = next; break; }
            catch (DocumentStore.Conflict conflict) { if (attempt == 7) throw new ConversationFailure("ASSISTANT_BUSY", "Assistant is busy; try again"); }
        }
        charged.set(false);
        tx.bindFence(new DocumentStore.Change(key, lease, null, true));
        try { return action.get(); }
        finally {
            tx.clearFence(); charged.remove();
            // A lost or expired lease must never release a new owner's fence.
            try { store.commit(List.of(new DocumentStore.Change(key, lease, null))); }
            catch (RuntimeException ignored) { /* Bounded expiry recovers a lease after disconnection/network failure. */ }
        }
    }
    @Override public void beforeModel() {
        if (charged.get() == null) throw new IllegalStateException("Provider call outside owned run");
        if (charged.get()) return;
        for (int attempt = 0; attempt < 8; attempt++) {
            long now = Instant.now().getEpochSecond();
            var changes = new ArrayList<DocumentStore.Change>();
            for (var window : List.of(new long[]{60, minuteLimit}, new long[]{86400, dayLimit})) {
                String key = "RATE#ASSISTANT#" + window[0] + "#" + now / window[0]; var before = store.get(key);
                int count = before == null ? 0 : before.path("count").asInt();
                if (count >= window[1]) throw new ConversationFailure("ASSISTANT_RATE_LIMITED", "Assistant usage limit reached; try again later");
                changes.add(new DocumentStore.Change(key, before, json.createObjectNode().put("count", count + 1).put("ttlEpoch", now + 172800)));
            }
            try { store.commit(changes); charged.set(true); return; }
            catch (DocumentStore.Conflict conflict) { if (attempt == 7) throw new ConversationFailure("ASSISTANT_BUSY", "Assistant is busy; try again"); }
        }
    }

}
