package com.sankalpa.adapter.out.llm;

import com.sankalpa.application.conversation.ConversationFailure;
import com.sankalpa.application.conversation.ConversationModel;

import java.util.ArrayDeque;
import java.util.Collection;
import java.util.Queue;

/** Deterministic model used by tests and local fake-model end-to-end runs. */
public final class ScriptedConversationModel implements ConversationModel {
    private final Queue<ModelTurn> turns = new ArrayDeque<>();

    public ScriptedConversationModel() {}
    public ScriptedConversationModel(Collection<ModelTurn> turns) { this.turns.addAll(turns); }
    public synchronized void enqueue(ModelTurn turn) { turns.add(turn); }

    @Override
    public synchronized ModelTurn respond(ModelRequest request) {
        ModelTurn turn = turns.poll();
        if (turn == null) {
            throw new ConversationFailure("ASSISTANT_UNAVAILABLE",
                    "No fake-model response is scripted for this run");
        }
        return turn;
    }
}
