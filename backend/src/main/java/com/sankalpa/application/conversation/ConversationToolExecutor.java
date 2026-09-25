package com.sankalpa.application.conversation;

import java.util.List;
import java.util.UUID;

public interface ConversationToolExecutor {
    List<ConversationModel.ToolDefinition> definitions(List<String> clientTools);
    Outcome execute(ConversationModel.ToolCall call, UUID threadId, UUID runId,
                    ConversationModel.Context context, List<String> clientTools);

    sealed interface Outcome permits ReadResult, ProposalResult, FrontendEffect {}
    record ReadResult(String json) implements Outcome {}
    record ProposalResult(Proposal proposal) implements Outcome {}
    record FrontendEffect(String name, String argumentsJson) implements Outcome {}
}
