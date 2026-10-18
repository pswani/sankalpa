# Conversational batch session logging

Status: implemented and verified locally. Date: October 17, 2026.
See [implementation review](implementation-review.md) for test evidence and remaining rollout gates.
No production practice data or deployed service was changed.

## Requirement and decision

A user can ask the assistant to record multiple performed sessions in one conversation request,
review one canonical proposal, and confirm once. For example, “I observed Brahmacharya every day
from September 14 through October 13, 2026” represents 30 daily entries. Confirmation invokes the
existing identified `SankalpaUseCases.logSession` 30 times in application code. There is no new
bulk REST persistence endpoint and no model invocation per entry. Confirmation remains a separate
AG-UI resume run: “one turn” means one user request and its approval interaction, not one HTTP call.

Select a bounded, atomic batch of at most 30 candidate entries for the first release. One invalid
entry causes zero new sessions to commit. This is simpler to explain and retry than partial success
for a small batch within the same service. Larger requests require explicitly confirmed chunks;
there is no automatic continuation or truncation. This refines the earlier suggestion of tracking
partial successes: that mechanism is unnecessary while the entire supported batch fits one transaction.

The model interprets intent and requests a typed batch proposal. Application code expands dates,
checks existing contributions, assigns identities, validates every entry, and executes the fixed
plan after approval. Generic “execute N arbitrary API calls,” model-authored scripts, and direct
mutation tools remain excluded. Single-entry logging and declarations keep their existing contracts.

## Analysis of the current implementation

| Evidence | Consequence |
|---|---|
| `ConversationCoordinator`: `MAX_ROUNDS=3`, `MAX_TOOL_CALLS=3`, exactly one request per response | Three read calls consume every round without a final answer. Thirty calls cannot run. |
| `LangChain4jConversationModel`: one-tool instruction; remaining tool budget is not used by the adapter | The model cannot plan reliably against the enforced budget. |
| `FixedConversationToolRegistry`: only `propose_log_session` for logging | No representation of a multi-entry intent. |
| `ProposalService`: one session ID per payload, terminal proposal interrupt | Thirty proposal requests would require separate approvals. |
| `TransactionalConversationUseCases` / `UseCaseTransactions` | Existing use cases can join a shared application transaction. |
| `DynamoRepository`: three distinct document writes per new session | Thirty entries fit the current transaction shape; arbitrary fan-out does not. |
| `ProposalService.confirm` catches domain failures inside the transaction | Copying that pattern into a loop could commit earlier entries while recording rejection. |
| Domain sessions store `LocalDateTime`; prompt requires exact past time | Date-only observances need clarification under the current domain contract. |

The screenshot proves budget exhaustion, not which reads were requested. Exact failing call order
requires sanitized run telemetry; this design does not claim a production trace was inspected.
The deployed AWS adapter is DynamoDB/Lambda; SQLite remains a supported local adapter.

## Semantics and limits

- One batch targets one explicit logging owner and one practice contract (`SINGLE_VOW_V1` or
  `LINKED_V1`), bound to the originating service instance. Resolve ambiguous vows before proposing.
- Initial tool supports daily ranges or explicit timestamps. Range endpoints are inclusive. The
  model must clarify ambiguous numeric dates. “Since” defaults to today in the configured service
  timezone, with that exact endpoint shown. Freeze the request clock during interpretation; do not
  move the endpoint when confirmation happens after midnight.
- Range expansion uses calendar dates, not repeated 24-hour durations. Times retain the existing
  wall-clock semantics. Ask for one exact daily time, or explicit individual times, before proposing.
  Never invent noon/midnight or silently introduce date-only facts. If today's chosen time is in the
  future, clarify whether to end yesterday or use a valid separate time today. True date-only
  observance is a separate domain requirement, not a hidden timestamp conversion.
- A range has at most 30 calendar dates; an explicit list has 1–30 timestamps. Bounds apply before
  skipping existing days. Reject duplicate timestamps inside one plan and ask for clarification;
  intentional same-time repeat sessions can still use the existing single-session flow.
- Daily range mode means “ensure one contributed session on each specified day.” Existing eligible
  contributions satisfy that day, even if owned by another linked vow; preserve them and skip the
  date. This is a command-specific satisfaction policy, never timestamp-based session identity.
- Explicit timestamp mode means “add these performed sessions.” Existing same-time facts are shown
  as repeat warnings but are not merged. The single confirmation explicitly approves those repeats.
- Query the complete bounded contribution set for the selected dates, using the shared linked-series
  predicate. Never infer absence from the model's 50-row recent-session tool or a truncated page.
  Incomplete reads or an exceeded scan safety limit fail with a helpful message and no proposal.
- Validate all requested dates against commitment and lifecycle history, including skipped dates'
  contributing facts. Never start, extend, resume, edit, or complete a vow to make the plan fit.
- Return an informational “all requested days already recorded” response when nothing needs adding;
  create no empty proposal. Never silently omit an invalid day.

## Tool and application contracts

Add allowlisted interpretation tool `propose_log_sessions`, available only to negotiated clients.
Strict JSON schema uses `additionalProperties:false`, a discriminated `oneOf`, UUID target, and:

```json
{"sankalpaId":"<uuid>","plan":{"mode":"DAILY_RANGE","from":"2026-09-14","through":"2026-10-13","localTime":"20:00:00"}}
```

Alternative plan: `{"mode":"EXPLICIT_TIMESTAMPS","occurredAt":["2026-09-14T20:00:00"]}`.
Both modes use ISO local date/time strings, with no offsets (matching stored wall-clock values).
Server validation enforces real dates/times, list bounds, exact fields, chronological canonical
ordering, known target, supported contract, and domain eligibility. Schema validation alone is
insufficient. Model output cannot supply session IDs, counts, skipped dates, expiry, or revisions.
A range that exceeds 30 returns typed `BATCH_TOO_LARGE` feedback with the count; the assistant asks
which range to process first. It does not split and execute behind one ambiguous approval.

Add `ConversationUseCases.proposeSessions(...)` and a typed `LOG_SESSIONS` proposal payload:

- proposal schema version 2 for this kind; existing kinds keep version 1;
- owner ID, title snapshot, series ID, practice contract, service instance ID;
- mode and frozen inclusive range or explicit input timestamps; configured timezone;
- base practice revision, requested count, canonical new entries `{sessionId, occurredAt}`;
- skipped dates with supporting contribution IDs, and repeat warnings for explicit mode;
- expiry and full canonical entry list, persisted before showing any confirmation.

Build the canonical plan, complete contribution reads, and capture its base revision inside one
consistent `UseCaseTransactions` attempt, with no model call inside it. Dynamo metadata validation
and JDBC ordering must prevent mixing a revision with reads from a different practice snapshot.
Persist the proposal only after this consistency check; a contended attempt is retried as a whole.

IDs are generated by application code once, durably stored, and reused across every confirmation
retry. Enforce unique source-run and pending-thread constraints as today. Multiple read calls do
not create multiple proposals. Proposal payload is immutable; correction cancels then re-proposes.
Result payload records the created session IDs, owner, count, and skipped count; do not overload
`resultResourceId` with one arbitrary session ID. Preserve that field's old meaning for old kinds.

## Model orchestration

Keep exactly one tool request per model response. One typed batch request carries up to 30 entries;
allowing unrelated simultaneous mutation requests adds no value to this requirement.

Allow three model tool calls and a fourth, text-only final model round. Tell the model its remaining
call budget on each invocation. On exhaustion, remove tool specifications and explicitly require a
text response or clarification. If it still emits a tool request, execute none and return a bounded,
friendly fallback. A successful proposal remains terminal and needs no final model round.
If the deadline is already exhausted, return the deterministic fallback without another provider call.
Maintain the existing single repair attempt; rejected requests consume the tool budget. All four
rounds share the existing wall-clock deadline; no multiplier per entry. Timeouts before proposal
creation mean no mutation. A replay of an already persisted proposal returns it before model work.

The coordinator counts model tool requests separately from confirmed domain commands: 30 session
use-case invocations are one confirmed plan, not 30 model rounds or a raised global tool allowance.
Do not give the model a direct session API tool or raise tool limits to 30 as the primary fix.

## Confirmation and atomic execution

Use the existing proposal lock/order, thread binding, confirmation identity, expiry, run fence,
and practice-contract checks. Add the batch dispatch before the current single-entry branches.

1. Resolve a recorded terminal outcome for the same confirmation first, before expiry or revision
   checks. A different confirmation for a resolved proposal receives `PROPOSAL_ALREADY_RESOLVED`.
2. For pending proposals, check expiry, service instance, contract, and negotiated feature support.
3. Acquire the existing series write ordering. Require current practice revision to equal the stored
   base revision. Any intervening practice mutation makes the preview stale; commit no sessions,
   reject with `PROPOSAL_STALE`, and ask for a fresh preview and confirmation. Never recompute a
   different set under the old approval. An unrelated practice change may conservatively invalidate
   a batch; this is acceptable for the single-user first release.
4. In one `UseCaseTransactions.write` attempt, revalidate every new entry, then invoke existing
   `logSession(owner, stableId, occurredAt, contract)` in canonical order. Calls join the outer
   boundary. Capture one execution clock for validation/logged-at consistency across the batch.
   Practice revision advances using existing commands; the base revision is compared once before
   writes, not again after each command.
5. Persist `EXECUTED`, confirmation binding, and the full result in that same transaction. Commit
   before emitting “30 sessions logged” and one refresh/navigation effect for the owner.

Every exception after staged/written entries must escape the write boundary, rolling back the
entire attempt. Do not catch a domain refusal inside the loop and save `REJECTED` in that attempt.
For a definitive failure, an outer handler may open a second transaction, lock the same pending
proposal, recheck ownership and outcome, and record `REJECTED` plus the attempted confirmation ID
and safe offending entry/reason. If a competing confirmation executed first, return its recorded
outcome rather than overwriting it. If recording rejection fails, leave it unresolved and report
an indeterminate failure; no success claim. Replays of recorded rejections return that rejection.
Transient contention, lease loss, infrastructure timeout, and uncertain commit are never converted
to definitive rejection: retry the same proposal/confirmation to resolve the recorded outcome.

Cancel before execution changes no domain state. Cancellation racing confirmation uses the same
ordering; whichever commits first wins. There is no mid-batch cancel, partial success, automatic
rollback-by-delete, background job, or server task queue in this release. A disconnected client
can retry its saved confirmation; server completion can outlive the SSE connection within existing
request/lease limits. Never infer cancellation from a broken stream.

## Persistence feasibility and deployment

SQLite: existing session facts, identity ledger, revision, and proposal result share one outer
transaction. No savepoint-based partial commits or nested independent transactions.

DynamoDB: current `DynamoRepository.save(Session)` stages `SESSION`, `JOURNAL`, and `OWNER` documents.
Thirty new entries use 90 actions. Resolution adds `PROPOSAL`, `CONFIRM`, deletion of `THREAD`, and
`META` (4); run fencing adds one condition action: expected total 95. `RUN` is retained and not
rewritten during resolution. Repeated META updates coalesce in `DynamoUnitOfWork`. No per-entry
proposal writes occur. Confirm actual staged distinct-key count in adapter tests; reject before
commit if above the adapter's 100-action bound. Also enforce serialized document/transaction byte
budgets with adapter validation; counts alone do not establish capacity. Use conservative 64 KiB
encoded proposal/result and SSE-event budgets and a 256 KiB input limit, inclusive of envelope.
Never split an oversized transaction into partial commits. Cap 30 remains fixed until a reviewed
persistence change proves a larger bound. No external HTTP fan-out occurs within a transaction.

Both JDBC and Dynamo proposal codecs must explicitly dispatch on kind/version, not the existing
binary “session else declaration” assumption. Unknown versions fail closed. Persisted v1 proposals
must still decode and replay. Extend result serialization without altering old result semantics.

## Client and protocol compatibility

Add advertised capability `assistantBatchSessions:1` and AG-UI header
`X-Sankalpa-Assistant-Batch-Sessions: 1`. This is transport negotiation, not a client-defined tool.
The existing expected-service-instance and practice-contract headers still apply. Advertise the
batch tool only for supported client/server combinations; old clients get text explaining that
multi-session confirmation needs an update. Old servers may ignore the new header but never expose
the tool; clients must not fabricate batch metadata. Server confirmation rejects a batch without
the version header even if the client knows its proposal ID. Native clients preserve pending
proposal/confirmation identity across transport retries and never render unknown kinds as a generic
Confirm button. Unknown versions show an update/cancel path, with no mutation.

The existing AG-UI interrupt carries `proposalType: LOG_SESSIONS`, `proposalVersion:2`, canonical
payload, and expiry. Native card shows owner, inclusive dates, daily time or each timestamp,
“30 requested / 27 new / 3 already recorded,” repeat warnings, timezone, and expandable full list.
Confirm label states the new count; Cancel and correction follow existing flows. Resuming after an
app restart recovers the same pending proposal via the existing server lookup, not a new plan.

Add errors `BATCH_TOO_LARGE`, `BATCH_INVALID_ENTRY`, `BATCH_READ_INCOMPLETE`, `PROPOSAL_STALE`,
and `ASSISTANT_BATCH_UNSUPPORTED`; sanitize domain refusal details. Tool validation errors use
structured feedback for clarification within the remaining budget. Stable transport errors include
safe recovery instructions. None claim a failed refresh means the committed batch failed.

After success refresh authoritative state once and navigate once. Do not enqueue these server-owned
session commands into the iOS offline journal or add optimistic per-entry facts. If the client has
unresolved local operations in the same series, synchronize before making a batch request; if that
cannot complete, block submission and explain why. Never hide those operations to force a preview.
A new local operation racing after preview either commits first and invalidates the revision or
commits after the batch as a separate user action; it is not part of this approval.

## Delivery and acceptance

1. Define the new kind/version, strict tool schema, immutable plan/result types, and fixtures.
2. Implement complete contribution reads, expansion, validation, stable identities, revision guard,
   and proposal persistence; no model needed for these tests.
3. Implement atomic confirmation and rollback-safe refusal handling on SQLite and DynamoDB.
4. Add version negotiation and native cards, saved confirmation retry, and refresh behavior.
5. Update model instructions, budget handling, and scripted model tests. Evaluate the screenshot
   wording plus range/list variants without production mutation.
6. Enable only after acceptance gates pass in both persistence profiles and a staging iPhone run.

Required tests cover 1/30/31 entries, 34-day screenshot range, invalid/duplicate/ambiguous dates,
missing time, future-today time, leap day/month boundary/DST calendar expansion, complete pagination,
all/partially recorded dates, linked contributions, explicit same-time repeats, invalid lifecycle,
stale preview, simultaneous confirm/cancel, response loss, expiry replay, lease loss, transient retry,
entry-17 failure rollback, crash before/after commit, v1 codec regression, old/new client combinations,
unknown proposal versions, payload/action limits, and local-journal interaction. Verify totals,
period outcomes, unique journal facts, and deletion of one resulting session through existing flows.
Use a counting use-case fake to prove exactly 30 canonical invocations and zero model calls during
confirmation; adapter tests must prove committed data, not merely invocation counts.

Acceptance: one request plus any necessary clarification yields one exact preview; one confirmation
creates every approved new session once or creates none; all retries return the same outcome;
no unsupported range is silently truncated; 30 new sessions fit real adapter limits. The review
record is [review-and-dry-run.md](review-and-dry-run.md). These are design dry runs and planned tests,
not claims of implemented or live-tested behavior.
