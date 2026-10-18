package com.sankalpa.adapter.out.dynamodb;

import com.fasterxml.jackson.databind.node.ObjectNode;
import java.util.List;
import java.util.Map;

/** Storage protocol: all compared documents are immutable snapshots. Null means absence. */
public interface DocumentStore {
    ObjectNode get(String key);
    Map<String, ObjectNode> query(String prefix);
    void commit(List<Change> changes);
    record Change(String key, ObjectNode before, ObjectNode after, boolean checkOnly) {
        public Change(String key, ObjectNode before, ObjectNode after) { this(key, before, after, false); }
    }
    final class Conflict extends RuntimeException { public Conflict() { super("Database contention"); } }
}
