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
    public static final int MAX_ROUNDS = 4;
    public static final int MAX_TOOL_CALLS = 3;
    private final ConversationModel model;
    private final ConversationContextLoader contexts;
    private final ConversationToolExecutor tools;
    private final ConversationUseCases proposals;
    private final ConversationRunGuard guard;
    private final long modelBudgetNanos;
    private final Set<UUID> activeThreads = ConcurrentHashMap.newKeySet();

    public ConversationCoordinator(ConversationModel model, ConversationContextLoader contexts,
            ConversationToolExecutor tools, ConversationUseCases proposals) {
        this(model, contexts, tools, proposals, null);
    }

    public ConversationCoordinator(ConversationModel model, ConversationContextLoader contexts,
            ConversationToolExecutor tools, ConversationUseCases proposals, ConversationRunGuard guard) {
        this(model, contexts, tools, proposals, guard, java.time.Duration.ofSeconds(30));
    }

    public ConversationCoordinator(ConversationModel model, ConversationContextLoader contexts,
            ConversationToolExecutor tools, ConversationUseCases proposals, ConversationRunGuard guard,
            java.time.Duration modelBudget) {
        if (modelBudget.isZero() || modelBudget.isNegative() || modelBudget.compareTo(java.time.Duration.ofSeconds(30)) > 0)
            throw new IllegalArgumentException("Model budget must be positive and at most 30 seconds");
        this.model = model; this.contexts = contexts; this.tools = tools; this.proposals = proposals;
        this.guard = guard; this.modelBudgetNanos = modelBudget.toNanos();
    }
    public RunResult run(RunInput input) {
        return guard == null ? runOwned(input) : guard.run(input, () -> runOwned(input));
    }
    private RunResult runOwned(RunInput input) {
        if (!activeThreads.add(input.threadId())) {
            throw new ConversationFailure("ASSISTANT_BUSY", "Another run is active for this conversation");
        }
        try {
            long deadline = System.nanoTime() + modelBudgetNanos;
            if (input.resume() != null) return resume(input);
            Proposal replay = proposals.findBySourceRunId(input.runId());
            if (replay != null) { requireBatchSupport(input, replay); contexts.requireReadable(replay,input.contract()); return proposalResult(input, replay); }
            Proposal pending = proposals.findPendingByThread(input.threadId());
            if (pending != null) {
                requireBatchSupport(input, pending);
                contexts.requireReadable(pending,input.contract());
                // The client may have lost the run that created it. Presenting it again lets the
                // user confirm or cancel instead of leaving the thread blocked.
                return new RunResult(List.of(new Message(UUID.randomUUID(),
                        "Please confirm or cancel this first. " + summary(pending))),
                        List.of(), pending, pending.id(), null);
            }
            ConversationModel.Context context = contexts.load(input.contract());
            List<ConversationModel.ToolResult> results = new ArrayList<>();
            int calls = 0;
            boolean repairUsed = false;
            for (int round = 0; round < MAX_ROUNDS; round++) {
                if (System.nanoTime() >= deadline) return fallback();
                if (guard != null) guard.beforeModel();
                ConversationModel.ModelTurn turn = respondBefore(deadline, new ConversationModel.ModelRequest(
                        input.messages(), context, calls >= MAX_TOOL_CALLS ? List.of() : tools.definitions(input.clientTools()), List.copyOf(results),
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
                if (++calls > MAX_TOOL_CALLS) return fallback();
                ConversationModel.ToolCall call = requested.getFirst();
                ConversationToolExecutor.Outcome outcome;
                try {
                    outcome = tools.execute(call, input.threadId(), input.runId(), context,
                            input.clientTools(),input.contract());
                } catch (ConversationFailure failure) {
                    boolean batchFeedback = failure.code().startsWith("BATCH_");
                    if (!batchFeedback && (repairUsed || !"ASSISTANT_COULD_NOT_INTERPRET".equals(failure.code()))) {
                        throw failure;
                    }
                    log.warn("Assistant tool request rejected ({}): {}", call.name(), failure.getMessage());
                    if (!batchFeedback) repairUsed = true;
                    results.add(new ConversationModel.ToolResult(call.id(), call.name(),
                            call.argumentsJson(), "{\"error\":\"" + (batchFeedback ? failure.code() : "INVALID_TOOL_REQUEST") + "\"}"));
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
                        call.argumentsJson(), ((ConversationToolExecutor.ReadResult) outcome).json()));
            }
            return fallback();
        } finally {
            activeThreads.remove(input.threadId());
        }
    }

    private ConversationModel.ModelTurn respondBefore(long deadline, ConversationModel.ModelRequest request) {
        var future = new java.util.concurrent.FutureTask<ConversationModel.ModelTurn>(() -> model.respond(request));
        Thread.startVirtualThread(future);
        try { return future.get(Math.max(1, deadline - System.nanoTime()), java.util.concurrent.TimeUnit.NANOSECONDS); }
        catch (java.util.concurrent.TimeoutException timeout) {
            future.cancel(true);
            return new ConversationModel.TextTurn(fallback().messages().getFirst().text());
        } catch (InterruptedException interrupted) {
            future.cancel(true); Thread.currentThread().interrupt();
            throw new ConversationFailure("ASSISTANT_UNAVAILABLE", "The assistant request was interrupted. Retry safely.");
        } catch (java.util.concurrent.ExecutionException failure) {
            if (failure.getCause() instanceof RuntimeException runtime) throw runtime;
            throw new ConversationFailure("ASSISTANT_UNAVAILABLE", "The assistant could not respond.");
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
        resolution = proposals.confirm(input.threadId(), resume.interruptId(), resume.confirmationId(),input.contract(), input.clientTools().contains("batch_sessions_v1"));
        Proposal p = resolution.proposal();
        if (p.status() == Proposal.Status.EXPIRED) {
            throw new ConversationFailure("PROPOSAL_EXPIRED",
                    "That proposal expired before it was confirmed. Nothing was changed; please ask again.");
        }
        if (p.status() == Proposal.Status.REJECTED) {
            throw new ConversationFailure("PROPOSAL_STALE".equals(p.failureCode()) ? "PROPOSAL_STALE" : "PROPOSAL_REJECTED",
                    "PROPOSAL_STALE".equals(p.failureCode()) ? "Your practice changed. Ask again for a fresh preview; nothing was saved."
                    : "The service refused that change (" + p.failureCode() + "). Nothing was saved.");
        }
        boolean batch = p.payload() instanceof Proposal.LogSessionsPayload;
        String reason = p.kind() == Proposal.Kind.DECLARE_SANKALPA ? "SANKALPA_DECLARED" : "SESSION_LOGGED";
        String text = batch ? ((Proposal.LogSessionsPayload) p.payload()).entries().size() + " sessions logged."
                : p.kind() == Proposal.Kind.LOG_SESSION ? "Your session was logged." : "Your Sankalpa was declared.";
        List<Effect> effects = new ArrayList<>();
        if (input.clientTools().contains("refresh_practice")) {
            effects.add(new Effect("refresh_practice", "{\"reason\":\"" + reason + "\"}"));
        }
        if (input.clientTools().contains("navigate_to_sankalpa")) {
            UUID sankalpaId = p.payload() instanceof Proposal.LogSessionPayload session
                    ? session.sankalpaId().value() : batch ? ((Proposal.LogSessionsPayload) p.payload()).sankalpaId().value() : p.resultResourceId();
            effects.add(new Effect("navigate_to_sankalpa",
                    "{\"sankalpaId\":\"" + sankalpaId + "\"}"));
        }
        return new RunResult(List.of(new Message(stable("resolved", p.id()), text)), effects,
                null, null, p.resultResourceId(), p.batchResult());
    }

    private RunResult proposalResult(RunInput input, Proposal proposal) {
        if (!proposal.threadId().equals(input.threadId())) {
            throw new ConversationFailure("AGUI_PROTOCOL_ERROR", "Run identity belongs to another thread");
        }
        return new RunResult(List.of(new Message(stable("proposal-message", proposal.sourceRunId()),
                summary(proposal))), List.of(), proposal, proposal.id(), null);
    }

    private static RunResult fallback() {
        return RunResult.text("I couldn't finish within this request's limits. Please choose a smaller date range or clarify the exact sessions to record. No unconfirmed changes were made.");
    }
    private static void requireBatchSupport(RunInput input, Proposal proposal) {
        if (proposal.kind() == Proposal.Kind.LOG_SESSIONS && !input.clientTools().contains("batch_sessions_v1"))
            throw new ConversationFailure("ASSISTANT_BATCH_UNSUPPORTED", "Update the app to review multiple sessions.");
    }
    private static String summary(Proposal proposal) {
        if (proposal.payload() instanceof Proposal.LogSessionsPayload p) {
            return "Record " + p.entries().size() + " sessions for “" + p.sankalpaTitle() + "”? "
                    + p.requestedCount() + " requested; " + p.skippedDays().size() + " days already recorded. Review all dates and times before confirming.";
        }
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
                           List<String> clientTools, Resume resume, com.sankalpa.application.PracticeContract contract) {
        public RunInput(UUID threadId,UUID runId,List<ConversationModel.Message> messages,List<String> clientTools,Resume resume) {
            this(threadId,runId,messages,clientTools,resume,com.sankalpa.application.PracticeContract.SINGLE_VOW_V1);
        }
        public RunInput {
            messages = List.copyOf(messages);
            clientTools = List.copyOf(clientTools);
        }
    }
    public record Resume(UUID interruptId, boolean cancelled, UUID confirmationId) {}
    public record Message(UUID id, String text) {}
    public record Effect(String name, String argumentsJson) {}
    public record RunResult(List<Message> messages, List<Effect> effects, Proposal proposal,
                            UUID interruptId, UUID resourceId, Proposal.BatchResult batchResult) {
        public RunResult(List<Message> messages, List<Effect> effects, Proposal proposal, UUID interruptId, UUID resourceId) {
            this(messages, effects, proposal, interruptId, resourceId, null);
        }
        static RunResult text(String text) {
            return new RunResult(List.of(new Message(UUID.randomUUID(), text)), List.of(),
                    null, null, null);
        }
    }
}
