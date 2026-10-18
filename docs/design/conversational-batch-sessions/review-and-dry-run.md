# Analyze → Design → Review with dry run → Fix

Date: October 17, 2026. Review performed against workspace source and documents by the author.
These are deterministic design walkthroughs and arithmetic checks, not executed integration tests,
independent review, or a production trace. Runtime tests remain delivery gates.

## Cycle 1 — Analyze and initial design

Inspected `ConversationCoordinator`, `FixedConversationToolRegistry`, `ProposalService`,
`TransactionalConversationUseCases`, `LangChain4jConversationModel`, `DynamoRepository`,
`DynamoUnitOfWork`, `JdbcUseCaseTransactions`, the native proposal decoder, conversation contracts,
session reliability, linked-series application architecture, and AWS deployment documentation.

Initial candidate: allow the model to emit many single-session requests and execute each after
one approval, keeping successful entries if later calls fail.

Review/dry run: thirty model calls exceed both current budgets; thirty individual proposal tools
terminate at the first proposal. Thirty independent commits need a persisted progress state machine,
partial-result UI, per-entry recovery, and cancellation semantics. Direct model mutation would also
bypass the existing approval boundary.

Fix: one typed range/list proposal, deterministic expansion, one approval, repeated existing
in-process use-case calls. Choose atomic batches within a tested storage bound; no partial-success
journal or new bulk REST endpoint. Preserve one tool per model response.

## Cycle 2 — Transaction dry run

Candidate: loop over `logSession` inside current `ProposalService.confirm` and reuse its catch.

| Step | Simulated state |
|---|---|
| Entries 1–16 succeed | Writes exist inside the outer transaction, not yet committed. |
| Entry 17 throws a domain refusal | Current-style inner catch could save REJECTED and return normally. |
| Outer boundary returns | Earlier entries could commit despite a rejection result. |

Finding: blocker; a promise of atomicity needs an explicit rollback path, not only an outer wrapper.

Fix: exception escapes the entire write attempt; all entries and proposal writes roll back. A
separate ordered transaction may record definitive refusal only after checking that the proposal
is still pending. Infrastructure/uncertain commit errors remain unresolved. A racing recorded
success always wins over a later attempt to record failure. Keep IDs in the immutable proposal.

Retest: with a refusal at entry 17, persisted new-session count is zero; with failure after commit
but before SSE, replay returns recorded IDs and count with no new session commands. Staged writes
are not reported as accepted. Adapter failure-injection tests are mandatory before release.

## Cycle 3 — Capacity and deployment dry run

Candidate: support up to 100 entries on the assumption that one session equals one write.

Finding: the deployed DynamoDB adapter writes SESSION, JOURNAL, OWNER per new session. Resolution
also writes PROPOSAL and CONFIRM, removes THREAD, and updates META; guard adds one fence action.
One hundred entries cannot fit. Original conversation documents also describe SQLite-only deployment.

Fix: cap 30 candidates before skipping. At maximum new entries: `3*30 + 4 + 1 = 95` actions.
The bound includes the fence. Repeated metadata writes coalesce; RUN is not rewritten. Require actual
staged action and byte checks; 31 entries are refused by product policy even though today's action
layout would total 98. Future adapter changes cannot silently consume the remaining headroom.
Update architecture and AWS references; require SQLite and DynamoDB acceptance.

Retest: 30 fits the known action layout; 31 produces a clarification rather than a partial batch;
serialized payload limits remain separately enforced. Larger batches require independent approvals.

## Cycle 4 — Intent, duplication, and time dry runs

| Scenario | Finding in earlier candidate | Fix and expected result |
|---|---|---|
| “Since September 14” on October 17 | Assumed 30 days | 34 inclusive days; offer September 14–October 13 (30), then October 14–17 (4), each approved separately. |
| Past observance has no time | Temptation to invent a representative timestamp | Ask for exact daily time; date-only sessions require a separate domain change. |
| Today's 20:00 at 18:10 | Range includes a future session | Clarify endpoint or a valid separate time; do not omit today silently. |
| One day has 80 contributed sessions | Recent tool is capped at 50 | Complete application read; never infer a missing day from a truncated page. |
| Existing fact belongs to linked source | Owner-only read would duplicate a satisfied day | Use shared contribution predicate; skip that date with supporting IDs. |
| Explicit same-time repeated activity | Day-based merging would destroy legitimate intent | Explicit mode adds distinct IDs with a visible repeat warning; daily mode only ensures a day is recorded. |
| 30-day range already fully recorded | Empty mutation proposal | Informational response, no proposal or confirmation. |
| Invalid lifecycle on one day | Temptation to silently skip | No proposal until user corrects request; domain remains authoritative. |
| Local offline create not yet on server | Preview could promise another entry for the same day | Synchronize same-series local work before submission; block if unresolved. |

Fixes are incorporated in semantics, client behavior, and validation requirements.
Calendar-expansion arithmetic covers leap day, month boundary, and DST dates without duration math.

## Cycle 5 — Concurrency, retry, protocol, and budget dry runs

| Scenario | Expected transition after fixes |
|---|---|
| Another session/lifecycle/delete commits after preview | Stored practice revision differs; reject stale proposal with zero new entries and require fresh approval. |
| Competing write commits during Dynamo read | META condition fails; existing retry re-reads state, sees stale revision, and makes no batch writes. |
| Two confirmations race | Proposal ordering and recorded confirmation bind one outcome; no duplicate entry identities. |
| Cancel races confirm | First committed resolution wins; never delete already accepted batch entries as compensation. |
| Same confirmation replayed after expiry or later session deletion | Recorded terminal outcome returned before expiry/revalidation; deleted entries are not recreated. |
| Different confirmation ID for resolved proposal | Already-resolved error, no commands. |
| Crash before commit | No sessions or executed outcome; replay same proposal/confirmation. |
| Commit succeeds but refresh/stream fails | Recorded result is authoritative; retry resolves it, then refresh; never create a fresh plan to retry. |
| Run lease expires before Dynamo commit | Fence rejects commit; no partial facts; retry same identity after ownership recovery. |
| Old client/new server | Batch tool withheld; unsupported explanation, no unrenderable approval. |
| Unknown kind/version reaches native decoder | Update/cancel path; no generic enabled Confirm. |
| Three read calls use tool budget | Fourth round has no tools and can respond; if deadline already exhausted, deterministic helpful fallback with no extra provider call. |
| Provider emits multiple tools | Execute none, existing fail-closed handling remains. |
| Malformed proposal request is repaired once | Repair consumes existing budget; no unbounded loop. |

Final fixes: explicit version header on proposal and resume, retained v1 codecs, structured batch
results, frozen range/time, revision checked once before command loop, no per-entry model calls,
full rollback before refusal recording, and bounded final response behavior.

## Final review assessment

No unresolved design blockers found in the final walkthrough. The design specifies field ownership,
confirmation, time semantics, domain validation, transaction boundaries, duplicate policy, linked
contributions, service binding, compatibility, capacity, and failure recovery without new domain
entities or generic execution permissions. Conservative revision invalidation, a 30-entry ceiling,
and exact-time clarification are deliberate product tradeoffs. Date-only observances and larger
atomic batches remain outside this release.

Implementation approval does not imply release acceptance: the test matrix in README.md, actual
DynamoDB action/byte checks, SQLite rollback checks, native negotiation/card tests, and staging
confirmation remain required. No live practice mutations were made during this design review.

## Executed documentation checks

A local standard-library date check verified inclusive counts for September 14–October 13 (30),
September 14–October 17 (34), October 14–17 (4), February 28–March 1 in leap year 2024 (3), and
October 31–November 2, 2026 across the configured US DST boundary (3 calendar dates). A separate
arithmetic assertion verified `3*30+4+1=95`. These checks validate calendar enumeration and the
source-derived write formula; they do not validate timezone conversion or actual database commits.
All 62 relative Markdown links across the 14 touched/new design documents resolved, and
`git diff --check` passed. No runtime tests were run because this change contains documentation only.
Final consistency review added an explicit requirement to construct the canonical preview and
capture its base revision in the same consistent persistence attempt, preventing mixed-snapshot
planning. The implementation must test that ordering on both adapters.
