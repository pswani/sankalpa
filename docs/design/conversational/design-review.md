# Design Review Record

This records the requested Design → Review → Fix loop. It is intentionally about consequential
findings, not a diary of every wording edit.

## Round 1 — Architecture and authority

### Initial design

- AG-UI between iOS and the service.
- Server-side LLM framework and tool calls.
- iOS tool handlers for application behavior.
- Potential Python LangChain/LangGraph service and possible MCP tools.

### Review findings

1. A Python sidecar creates a second deployment, configuration surface, health boundary, and state
   story for two initial write journeys.
2. MCP adds value between independent hosts and tool servers, not between classes in one Spring
   process.
3. Direct model mutation tools make confirmation, retries, and auditability fragile.
4. Treating proposal display as a frontend tool duplicates the proposal state needed for approval.
5. Letting iOS apply model-generated domain state creates a second source of truth.

### Fixes

- Keep one Spring Boot service and use Java-native LangChain4j behind a port.
- Defer MCP until an independent AI host needs Sankalpa.
- Replace direct mutations with persisted proposal tools.
- Use AG-UI interrupt/resume for approval, which is the protocol's native human-input boundary.
- Restrict frontend tools to refresh/navigation and always reload authoritative server state.

## Round 2 — Reliability and failure behavior

### Review findings

1. A lost confirmation response could duplicate a session or declaration.
2. The domain may change after a proposal is shown.
3. A broken SSE stream needs different handling before and after confirmation.
4. Persisting an entire agent thread/checkpoint graph would be disproportionate.
5. The original voice screen had no explicit transition from transcription to submission.

### Fixes

- Persist proposals with confirmation identity and recorded results.
- Confirm and mutate in one database transaction; revalidate immediately before execution.
- Make pre-confirmation runs non-mutating and confirmation resumes idempotent.
- Persist only proposals; keep the bounded display transcript locally on iOS.
- Make speech populate the ordinary editable composer and require an explicit Send action.

## Round 3 — Domain fit and scope

### Review findings

1. Earlier examples invented reminder/preferred-time fields that do not exist in the domain.
2. “This morning” cannot safely become an exact stored `LocalDateTime` without another choice.
3. Automatic conversion of “six months” to a period count can be wrong for different start dates
   and period units.
4. Supporting every lifecycle and correction command in the first release broadens tool and test
   scope before the core interaction is proven.
5. Loading every possible tool dynamically is unnecessary for a small fixed capability set.

### Fixes

- Proposal schemas now contain only existing domain fields.
- Exact time is required for past/daypart logging; “now” is used only when the user says now or
  just finished.
- Unrepresentable duration language triggers clarification.
- V1 is read/list, log session, and declare Sankalpa. Lifecycle actions are deferred.
- Use a fixed code-owned tool registry and preload the bounded single-user catalog.

## Round 4 — Security, operability, and maintainability

### Review findings

1. Current service documentation says authentication and TLS are absent.
2. Stored Sankalpa text can contain prompt-like content.
3. Framework/provider types could spread through the application.
4. Live-model tests are variable and unsuitable as the primary correctness gate.
5. An evolving protocol consumed from `main` could break the native Swift implementation.
6. Returning a successful proposal to the model for another prose round could let generated text
   contradict canonical proposal values.
7. Automatic framework tool execution would hide the exact authorization and terminal-proposal
   boundary inside library behavior.
8. Migrating the existing MVC service to a reactive stack merely for assistant output would add
   unrelated operational and testing work.
9. A free-form correction sent while an interrupt is open would have undefined ordering against
   the pending confirmation.

### Fixes

- Require TLS and a simple single-user bearer credential before remote/physical-device use.
- Treat user and stored content as untrusted data; tool selection stays server-owned.
- Introduce an application-owned `ConversationModel` port.
- Make all correctness tests run with a scripted fake model; keep live calls in a promotion eval.
- Pin AG-UI and test native Swift types against upstream fixtures.
- Treat proposal tools as terminal and render their summary from canonical server data.
- Use the low-level LangChain4j tool-request API; the application coordinator executes tools.
- Keep Spring MVC and emit the small AG-UI stream through a bounded `SseEmitter` executor.
- Resolve the open interrupt before accepting correction text.

## Round 5 — Practicality and implementation readiness

### Review findings

1. The design stated that confirmation and mutation are atomic but did not name the outer
   transaction owner; the existing transaction wrapper covers one domain use-case call at a time.
2. LangChain4j may return several tool requests in one response, while the proposal contract allows
   only one interrupt.
3. A durable conversational `revise` workflow added replay and recovery state disproportionate to
   the first release.
4. An unbounded description could produce a valid proposal larger than the SSE event limit.
5. The failure matrix contradicted the architecture about replaying a proposal-producing `runId`.
6. The server cannot see a durable session operation that still exists only in the iOS journal, so
   it cannot reliably label every possible rapid repeat.

### Fixes

- Add one `TransactionalConversationUseCases` boundary around proposal resolution and the existing
  domain use case; acquire the SQLite write reservation before reading proposal state and never hold
  it across a model call.
- Accept one model tool request per response and fail closed before executing any request when the
  model returns several.
- Replace `revise` with an idempotent cancel-then-send client sequence. Native Edit follows the
  existing manual command path. Remove the now-unused `SUPERSEDED` state; a pending thread accepts
  only confirmation or cancellation.
- Limit conversational declaration titles to 200 characters and descriptions to 2,000 characters;
  bound existing description context separately.
- Replay the same proposal and deterministic event IDs for the same proposal-producing `runId`.
  Treat `runId` as the identity of a logical run and reuse it only for retry of that run.
- Rely on the mandatory conversational confirmation to satisfy the rapid-repeat confirmation rule;
  do not promise an additional server-generated warning.

## Final validation

| Concern | Result | Evidence in design |
|---|---|---|
| Simple deployment | Pass | One Spring JAR, SQLite, no sidecar |
| Domain authority | Pass | Existing use cases execute every mutation |
| Natural-language flexibility | Pass | Model interpretation with bounded tools |
| Human control | Pass | Persisted proposal plus interrupt/resume |
| Retry safety | Pass | Confirmation identity and replayed result |
| Ambiguity | Pass | Clarification and visible canonical values |
| iOS/server separation | Pass | Presentation tools only; refresh after success |
| Protocol scope | Pass | Minimal pinned AG-UI profile |
| Framework isolation | Pass | `ConversationModel` port |
| Security | Pass for design | Auth/TLS prerequisite, fixed tools, strict validation |
| Offline behavior | Pass | Assistant online-only; manual paths remain |
| Testability | Pass | Fake model, contract fixtures, E2E, eval corpus |
| Extensibility | Pass | New proposal kinds fit same executor boundary |
| Auditability | Pass | Proposal lifecycle and identifiers, content-minimal logs |

## Remaining prerequisites, not open design questions

These are implementation prerequisites with already-defined answers:

1. Add the conversational behavior to functional requirements before release.
2. Finish the session command identity work referenced by the session-reliability design.
3. Select and pin exact AG-UI and LangChain4j versions during implementation.
4. Select the initial provider/model through configuration and run the promotion corpus.
5. Configure authentication/TLS for the deployment used by the physical phone.

No additional framework, agent runtime, MCP server, message broker, vector store, or persistence
service is required to begin implementation.
