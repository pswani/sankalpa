package com.sankalpa.application.conversation;

import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.List;
import java.util.Set;
import java.util.UUID;
import java.util.concurrent.ConcurrentHashMap;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

/** Bounded, model-independent orchestration. It never holds a transaction across model calls. */
public final class ConversationCoordinator {
    private static final Logger log = LoggerFactory.getLogger(ConversationCoordinator.class);
    public static final int MAX_ROUNDS = 3;
    public static final int MAX_TOOL_CALLS = 3;
    private final ConversationModel model;
    private final ConversationContextLoader contexts;
    private final ConversationToolExecutor tools;
    private final ConversationUseCases proposals;
    private final Set<UUID> activeThreads = ConcurrentHashMap.newKeySet();

    public ConversationCoordinator(ConversationModel model, ConversationContextLoader contexts,
                                   ConversationToolExecutor tools, ConversationUseCases proposals) {
        this.model = model;
        this.contexts = contexts;
        this.tools = tools;
        this.proposals = proposals;
    }

    public RunResult run(RunInput input) {
        if (!activeThreads.add(input.threadId())) {
            throw new ConversationFailure("ASSISTANT_BUSY", "Another run is active for this conversation");
        }
        try {
            if (input.resume() != null) return resume(input);
            Proposal replay = proposals.findBySourceRunId(input.runId());
            if (replay != null) return proposalResult(input, replay);
            if (proposals.findPendingByThread(input.threadId()) != null) {
                throw new ConversationFailure("PROPOSAL_ALREADY_RESOLVED",
                        "Confirm or cancel the pending proposal first");
            }
            ConversationModel.Context context = contexts.load();
            List<ConversationModel.ToolResult> results = new ArrayList<>();
            int calls = 0;
            boolean repairUsed = false;
            for (int round = 0; round < MAX_ROUNDS; round++) {
                ConversationModel.ModelTurn turn = model.respond(new ConversationModel.ModelRequest(
                        input.messages(), context, tools.definitions(input.clientTools()), List.copyOf(results),
                        MAX_TOOL_CALLS - calls));
                if (turn instanceof ConversationModel.TextTurn text) {
                    if (text.text() == null || text.text().isBlank()) invalid();
                    return RunResult.text(text.text().trim());
                }
                if (turn instanceof ConversationModel.RefusalTurn) {
                    throw new ConversationFailure("ASSISTANT_COULD_NOT_INTERPRET",
                            "The assistant could not interpret that request");
                }
                List<ConversationModel.ToolCall> requested =
                        ((ConversationModel.ToolRequestsTurn) turn).requests();
                if (requested == null || requested.size() != 1) invalid();
                if (++calls > MAX_TOOL_CALLS) {
                    throw new ConversationFailure("ASSISTANT_LIMIT_REACHED", "Assistant tool limit reached");
                }
                ConversationModel.ToolCall call = requested.getFirst();
                ConversationToolExecutor.Outcome outcome;
                try {
                    outcome = tools.execute(call, input.threadId(), input.runId(), context,
                            input.clientTools());
                } catch (ConversationFailure failure) {
                    if (repairUsed || !"ASSISTANT_COULD_NOT_INTERPRET".equals(failure.code())) {
                        throw failure;
                    }
                    log.warn("Assistant tool request rejected ({}): {}", call.name(), failure.getMessage());
                    repairUsed = true;
                    results.add(new ConversationModel.ToolResult(call.id(), call.name(),
                            "{\"error\":\"INVALID_TOOL_REQUEST\"}"));
                    continue;
                }
                if (outcome instanceof ConversationToolExecutor.ProposalResult proposal) {
                    return proposalResult(input, proposal.proposal());
                }
                if (outcome instanceof ConversationToolExecutor.FrontendEffect effect) {
                    return new RunResult(List.of(), List.of(new Effect(effect.name(), effect.argumentsJson())),
                            null, null, null);
                }
                results.add(new ConversationModel.ToolResult(call.id(), call.name(),
                        ((ConversationToolExecutor.ReadResult) outcome).json()));
            }
            throw new ConversationFailure("ASSISTANT_LIMIT_REACHED", "Assistant round limit reached");
        } finally {
            activeThreads.remove(input.threadId());
        }
    }

    private RunResult resume(RunInput input) {
        Resume resume = input.resume();
        ConversationUseCases.Resolution resolution;
        if (resume.cancelled()) {
            resolution = proposals.cancel(input.threadId(), resume.interruptId());
            return new RunResult(List.of(new Message(stable("cancel", resume.interruptId()),
                    "Cancelled. Nothing was changed.")), List.of(), null, null, null);
        }
        if (resume.confirmationId() == null) invalid();
        resolution = proposals.confirm(input.threadId(), resume.interruptId(), resume.confirmationId());
        Proposal p = resolution.proposal();
        if (p.status() == Proposal.Status.REJECTED) {
            throw new ConversationFailure("PROPOSAL_REJECTED", p.failureCode());
        }
        String reason = p.kind() == Proposal.Kind.LOG_SESSION ? "SESSION_LOGGED" : "SANKALPA_DECLARED";
        String text = p.kind() == Proposal.Kind.LOG_SESSION
                ? "Your session was logged." : "Your Sankalpa was declared.";
        List<Effect> effects = new ArrayList<>();
        if (input.clientTools().contains("refresh_practice")) {
            effects.add(new Effect("refresh_practice", "{\"reason\":\"" + reason + "\"}"));
        }
        if (input.clientTools().contains("navigate_to_sankalpa")) {
            effects.add(new Effect("navigate_to_sankalpa",
                    "{\"sankalpaId\":\"" + p.resultResourceId() + "\"}"));
        }
        return new RunResult(List.of(new Message(stable("resolved", p.id()), text)), effects,
                null, null, p.resultResourceId());
    }

    private RunResult proposalResult(RunInput input, Proposal proposal) {
        if (!proposal.threadId().equals(input.threadId())) {
            throw new ConversationFailure("AGUI_PROTOCOL_ERROR", "Run identity belongs to another thread");
        }
        return new RunResult(List.of(new Message(stable("proposal-message", proposal.sourceRunId()),
                summary(proposal))), List.of(), proposal, proposal.id(), null);
    }

    private static String summary(Proposal proposal) {
        if (proposal.payload() instanceof Proposal.LogSessionPayload p) {
            return "Log a session for “" + p.sankalpaTitle() + "” at " + p.occurredAt() + "?";
        }
        Proposal.DeclareSankalpaPayload p = (Proposal.DeclareSankalpaPayload) proposal.payload();
        return "Declare “" + p.title() + "” — " + p.timesPerPeriod() + " per "
                + p.periodUnit().name().toLowerCase() + " from " + p.startDate() + "?";
    }

    private static UUID stable(String prefix, UUID id) {
        return UUID.nameUUIDFromBytes((prefix + ":" + id).getBytes(StandardCharsets.UTF_8));
    }

    private static void invalid() {
        throw new ConversationFailure("ASSISTANT_COULD_NOT_INTERPRET",
                "The assistant returned an unsupported response");
    }

    public record RunInput(UUID threadId, UUID runId, List<ConversationModel.Message> messages,
                           List<String> clientTools, Resume resume) {
        public RunInput {
            messages = List.copyOf(messages);
            clientTools = List.copyOf(clientTools);
        }
    }
    public record Resume(UUID interruptId, boolean cancelled, UUID confirmationId) {}
    public record Message(UUID id, String text) {}
    public record Effect(String name, String argumentsJson) {}
    public record RunResult(List<Message> messages, List<Effect> effects, Proposal proposal,
                            UUID interruptId, UUID resourceId) {
        static RunResult text(String text) {
            return new RunResult(List.of(new Message(UUID.randomUUID(), text)), List.of(),
                    null, null, null);
        }
    }
}
