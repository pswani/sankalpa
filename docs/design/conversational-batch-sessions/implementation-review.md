# Batch-session implementation and review

Date: October 17, 2026. Status: implemented and verified locally; not deployed.

## Delivered behavior

One negotiated `propose_log_sessions` call creates one version-2 `LOG_SESSIONS` proposal containing
up to 30 identified sessions. The native card shows the owner, requested/new/skipped counts,
timezone, range/time, repeat warnings, and an expandable full list. One approval invokes the
existing session command for every new entry without a model call. Success records a structured
result and produces one refresh and one navigation effect when advertised.

Daily ranges use complete contributing-history reads and skip days already recorded. Explicit
entries preserve intentional repeats. Missing/invalid times, future occurrences, 31+ entries,
incomplete reads, oversized previews, stale practice revisions, and unsupported clients fail
without changing practice data. Requests such as the original 34-day example require explicitly
chosen chunks; the implementation never silently truncates the request.

Session facts, identities, revision updates, and executed proposal resolution share one transaction.
The batch refusal exception crosses that boundary before a second ordered transaction records
rejection. Replay uses the stored IDs and outcome, including after expiry or deletion of a resulting
session. Cancellation, unknown proposal versions, and unconfirmed tool calls never execute a batch.

## Implement → test → review → fix cycles

| Cycle | Review finding | Fix and verification |
|---|---|---|
| 1: application orchestration | Reusing the old inner catch could commit entries 1–16 when entry 17 failed. | Separate rollback and rejection transactions. H2 and Dynamo injected-refusal tests assert zero facts/identities and unchanged revision; SQLite trigger test asserts rollback after 16 inserts. |
| 2: persistence and upgrade | Binary payload codecs treated every other kind as declaration; old SQLite CHECK rejected the new kind. | Explicit kind/version dispatch in both codecs; transactional SQLite table upgrade preserves old rows/indexes. Upgrade and repeated-start migration test passes. |
| 3: complete reads and contracts | Linked cursor reads require LINKED_V1 even for a single-vow caller. | Use the legacy complete paginated reader for SINGLE_VOW_V1 and contribution cursor reader for LINKED_V1. SQLite single-vow and 205-session linked pagination tests pass. |
| 4: ordering and replay | Revision checks before series ordering could leave a race; record replay must precede expiry/revalidation. | Acquire the existing series write ordering before revision comparison. Concurrent confirmation, stale preview, post-deletion replay, expiry replay, and Dynamo contention tests pass. |
| 5: capacity and provider | Counting one action per session would exceed Dynamo capacity; three read rounds still needed a final response. | Thirty-entry cap, 48 KiB persisted-preview ceiling, actual 95-action assertion including fence, real SDK commit, fourth text-only round, and shared provider deadline with cancellation. Timeout test verifies ownership release. |
| 6: native approval and recovery | A lost confirmation/app restart could lose its identity; persisted metadata could bypass wire validation; a client tool name could spoof negotiation. | Atomic service-scoped recovery checkpoint before delivery, same identity on retry/relaunch, shared preview validation on decode, strict version gate, and server-owned header negotiation. Recovery, corrupt-file, malformed-card, header, and spoof tests pass. |
| 7: final integration | UI compilation and codec/provider conversion needed verification beyond core tests. | Full Swift package tests, native iOS build for both simulator architectures, LangChain4j union-schema conversion, full backend suite including DynamoDB Local and HTTP tests pass. |

The review was performed by the implementing agent against source, contracts, test outcomes, and
failure walkthroughs. No independent review or live model-provider evaluation is claimed.

## Implementation refinements

- Use a structurally disjoint `anyOf` for the strict tool schema; the literal `mode` and exact
  properties preserve the design's discriminated-union semantics. The LangChain4j adapter test
  verifies that the tool specification can be constructed.
- Persist the immutable canonical entry list and executed status together. `Proposal.batchResult()`
  derives the complete result from that recorded state, avoiding a redundant second list that could
  drift. The wire success outcome includes owner, session IDs, created count, and skipped count.
- Wire metadata emits UUID strings; persistence uses the existing typed identity encoding.
- Scope one execution clock across all repeated session commands. There is no model call or HTTP
  fan-out inside confirmation.
- Reserve 48 KiB for persisted payloads to leave room inside the 64 KiB event limit. Dynamo's
  existing adapter also checks real action, item, and transaction-size limits. No oversized operation
  is split into partial commits.
- The native preflight conservatively synchronizes all unresolved local session operations before
  sending, rather than attempting to infer the target series before the model interprets the request.
  Batch confirmation also holds the existing series interaction guard, rechecked after async preflight.
- Recovery files are scoped to service instance and contract, written atomically, and preserve
  malformed data while blocking new delivery. Only the last 80 displayed messages are checkpointed;
  model input retains the existing 20-message bound. No server-owned batch is queued in the iOS
  session operation journal.

## Final verification evidence

| Check | Result |
|---|---|
| Complete Maven backend suite with `SANKALPA_TEST_DYNAMODB_ENDPOINT=http://127.0.0.1:18017` | 134 tests, 0 failures, 0 errors, 0 skipped |
| Batch conversation integration tests | 14 passing: atomicity, replay, cancellation/expiry, stale preview, complete contributions, bounds, payload size, negotiated wire metadata, malformed dates, spoof resistance, model-free confirmation, final round, provider timeout |
| Production SQLite driver upgrade/rollback test | Passed, including preserved old row/index, idempotent migration, failed-entry rollback and successful same-identity retry |
| Dynamo in-memory adapter suite | 11 passing, including 95-action assertion, response loss, contention, refusal rollback, expired fence and codec reload |
| Real DynamoDB Local SDK suite | 4 passing, including 30-session atomic commit under fence and replay |
| Dynamo HTTP integration suite | 2 passing |
| Swift package suites | 223 passing: 95 domain, 109 storage/application, 19 conversation/protocol |
| iOS simulator build (`xcodebuild`, signing disabled) | BUILD SUCCEEDED for arm64 and x86_64 |
| `git diff --check` | Passed |

Reproduction commands (from the respective directories):

```sh
# backend; isolated DynamoDB Local 2.6.1 on localhost:18017
SANKALPA_TEST_DYNAMODB_ENDPOINT=http://127.0.0.1:18017 \
  mvn -Dmaven.repo.local=.m2/repository test

# app/SankalpaCore
CLANG_MODULE_CACHE_PATH=/tmp/sankalpa-batch-clang \
  swift test --disable-sandbox --scratch-path /tmp/sankalpa-batch-swift

# app
xcodebuild -project Sankalpa.xcodeproj -scheme Sankalpa -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/sankalpa-batch-ios \
  -disableAutomaticPackageResolution CODE_SIGNING_ALLOWED=NO build
```

Temporary test resources used an in-memory local DynamoDB container, temporary tables, temporary
SQLite databases, and build output directories. No production practice mutations or deployment
were performed. Approval review initially hit a usage limit; the localhost test run was subsequently
approved after the reset and completed successfully.

## Rollout gates remaining

Before production enablement, perform the planned staging iPhone confirmation/accessibility
journey and configured-provider evaluation on an isolated practice. Physical-device UX, model
interpretation quality, and production deployment are not established by local code tests. The
30-entry cap and exact-time requirement remain deliberate product limits; date-only observance
and larger batches require separate requirements/design work.
