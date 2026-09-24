# Session Reliability And Correction Design

**Status:** Implemented and verified on the current branch  
**Scope:** Current `del-sankalpa` branch, `backend/` and its service-backed `app/` iOS client  
**Requirement source:** [Sankalpa — Reliable logging and correction](../../requirements/sankalpa.md#reliable-logging-and-correction)

`app2/` is a separate local-only application and is not part of this server/client implementation
plan. It must not be used as the source tree for the changes below.

## 1. Outcome

One user action has one stable session identity from the moment it is accepted on the device until
the server accepts or rejects it. Retries reuse that identity. A deliberately confirmed second
action gets a different identity even when it has the same performed-at time.

Deletion is permanent. It removes the session fact from every read calculation and reserves the
identity so a delayed create cannot bring the session back. The client represents unresolved
creates and deletes as durable operations and applies them over its server snapshot, so the display
does not reverse while the service is unreachable.

This design adds no session editing, soft-deleted session history, server event bus, or server
outbox. It does not change commitment, lifecycle, or period-boundary rules.

## 2. Current-Branch Findings

The design is based on the code that exists on this branch, not on another implementation:

| Current behavior | Reliability gap | Required change |
|---|---|---|
| `SankalpaService.logSession` creates a new `SessionId` for every request. | A retry after a lost response can create a second session. | Generate the ID once on the client and use it as the command identity on every attempt. |
| The POST body contains only `occurredAt`. | The server cannot recognize a replay. | Send the same client UUID in the body and `Idempotency-Key`; return it as the session ID. |
| Offline reconciliation matches `(sankalpaId, occurredAt)`. | Two intentional sessions at the same time can be silently merged. | Reconcile new operations only by session ID. Preserve an old-format outbox and fail closed instead of value-matching it. |
| `PracticeCache` persists only pending creates. | Undo or deletion can be lost, and accepted writes can disappear after a failed refresh. | Persist a versioned operation journal containing creates, deletes, recent-log guards, and rejection notices. |
| An unreadable outbox is renamed and logging restarts from an empty one. | New writes can hide an unresolved recovery problem. | Persist a recovery marker and block session mutation/delivery until explicit recovery or discard. |
| The snapshot is `server + pending creates`. | Pending deletion cannot stay excluded locally. | Overlay creates and deletion suppressions over an unchanged server snapshot. |
| Refresh is capped at ten session pages and history is date-bounded. | Some logged sessions can become impossible to delete. | Read all validated pages for the local snapshot and expose full session history for correction. |
| The cache keeps a total separate from its capped session collection. | A pending or accepted delete can change one path but not another. | After loading complete history, derive every total from the same overlaid session collection. |
| Log controls coordinate only inside the modal form. | Today and detail buttons can submit overlapping actions. | Put processing and repeat-confirmation coordination in `AppModel`, shared by every entry point. |
| The server has only `practice_session`. | Delete-before-create and permanent identity reservation are impossible. | Add one global session-identity ledger used by both create and delete transactions. |
| Pending operations follow a changed service address. | An operation can be sent to a different server than the one that accepted it locally. | Bind operations to their originating service instance, not its address, and never retarget them implicitly. |
| The legacy outbox records no service instance. | Its destination and value-based matches cannot be proven after upgrade. | Preserve it in recovery, block delivery and new session mutation, and require an explicit warned discard rather than guessing. |

## 3. System Invariants

These invariants are the implementation review checklist:

1. A logging action creates one UUID before its first network attempt and never changes it.
2. The server has exactly one durable identity state for a session UUID: `ACTIVE` or `DELETED`.
3. `ACTIVE` has exactly one matching session fact. `DELETED` has no session fact.
4. An exact replay returns the original session without rechecking current lifecycle eligibility.
5. Reusing an identity with a different sankalpa or performed-at time is a conflict, never a new
   session.
6. Different identities are independent, even when all other values are identical.
7. Delete wins over every delayed create with the same identity, including delete-before-create.
8. Active-session reads and all derived calculations exclude deleted identities.
9. The client acknowledges an offline action only after its operation journal is durably written.
10. A pending delete suppresses the session from all local reads until accepted or rejected.
11. A server-accepted create or delete is applied to the durable client snapshot before its pending
    operation is removed.
12. Operations are retried only against the persisted service instance that originated them.
13. Reconciliation refusals and their user notices survive relaunch until acknowledged.
14. The one-minute guard measures completion/durable-pending time, not performed-at time.
15. Undo targets the exact receipt returned by the log action.
16. Every identified session command names its expected persistent service instance, and a server
    rejects an instance mismatch before changing data.
17. A response may complete only the exact journal operation revision that sent it; it cannot
    remove or overwrite a newer Undo/delete decision for the same session.

## 4. End-To-End Flows

### 4.1 Online log and replay

```mermaid
sequenceDiagram
  actor User
  participant UI as iOS UI
  participant Journal as Operation journal
  participant API as Server API
  participant DB as Session identity ledger

  User->>UI: Log session
  UI->>UI: Create session UUID; mark processing
  UI->>Journal: Persist pending create + recent guard
  Journal-->>UI: Durable
  UI->>API: POST identity + expected service instance
  API->>DB: Claim identity and insert session atomically
  DB-->>API: Created
  API-->>UI: 201 and session with same UUID
  UI->>Journal: Apply session to cache, then remove operation
  UI-->>User: Accepted + Undo

  Note over UI,API: If the response is lost, the durable operation remains
  UI->>API: Retry POST with the same key and values
  API->>DB: Find exact ACTIVE identity
  API-->>UI: 200 and original session
```

### 4.2 Offline log, Undo, and delete-before-create

```mermaid
sequenceDiagram
  actor User
  participant UI as iOS UI
  participant Journal as Operation journal
  participant API as Server API
  participant DB as Session identity ledger

  User->>UI: Log session
  UI->>Journal: Persist pending create
  UI->>API: POST
  API--xUI: Unreachable
  UI-->>User: Pending on this device + Undo
  User->>UI: Undo
  UI->>Journal: Atomically replace create with pending delete
  UI-->>User: Removed; deletion pending
  UI->>API: DELETE exact UUID + expected service instance
  API->>DB: Claim identity as DELETED
  API-->>UI: 204
  UI->>Journal: Apply deletion to cache, then remove operation

  Note over UI,DB: Any delayed POST for the UUID receives SESSION_DELETED
```

### 4.3 Pending deletion rejection

The client suppresses the selected session immediately. If the service rejects the deletion, the
client atomically removes the suppression and records a durable notice. Removing the overlay
reveals the unchanged server snapshot again; a refresh then confirms it. The notice remains until
the user acknowledges it.

## 5. Server Design

### 5.1 Command identity

`SessionId` is both the session identity and the idempotency identity for `LogSession`. The updated
client generates it before writing its local operation. It sends the canonical UUID both as
`LogSessionRequest.id` and in the `Idempotency-Key` header on every POST attempt. The duplication is
intentional: the body remains self-describing and a proxy that strips a custom header does not
erase command identity. If both values are present, the server requires them to match. Every new
client mutation also sends `Sankalpa-Service-Instance` with the journal's expected instance UUID;
the server compares it with its durable metadata before loading a sankalpa or changing any data.

The application signature becomes conceptually:

```java
SessionLogResult logSession(
    SankalpaId sankalpaId,
    SessionId sessionId,
    LocalDateTime occurredAt
);

record SessionLogResult(Session session, boolean created) {}
```

`loggedAt` is server time from the first successful creation. A replay returns the stored value.

### 5.2 Global identity ledger

A separate tombstone table is insufficient: a create under sankalpa A and a delete-before-create
under sankalpa B could insert into two different tables concurrently. Both would commit, leaving
one UUID simultaneously active and deleted. Both commands must contend on one primary key.

Add:

| Column | Rule |
|---|---|
| `session_id` | UUID text, primary key |
| `sankalpa_id` | Owning sankalpa, immutable |
| `identity_state` | `ACTIVE` or `DELETED` |

The service also has one durable identity record:

| Metadata key | Rule |
|---|---|
| `service_instance_id` | UUID generated once for this logical data store and returned by the capability endpoint |

The ledger is technical command state, not a user-visible deletion audit. It intentionally retains
only identity, owner, and state after deletion; the session's performed/logged fact is physically
removed from `practice_session`.

Migration creates the ledger and backfills every existing `practice_session` as `ACTIVE` before
new commands are accepted. It is restart-safe and must fail startup rather than serve writes with a
partially backfilled ledger. New installations create the ledger before accepting session writes.

With the current always-run `schema.sql`, use a portable idempotent shape equivalent to:

```sql
CREATE TABLE IF NOT EXISTS session_identity (
    session_id VARCHAR(36) PRIMARY KEY,
    sankalpa_id VARCHAR(36) NOT NULL,
    identity_state VARCHAR(16) NOT NULL CHECK (identity_state IN ('ACTIVE', 'DELETED')),
    FOREIGN KEY (sankalpa_id) REFERENCES sankalpa(id) ON DELETE RESTRICT
);

CREATE TABLE IF NOT EXISTS service_metadata (
    metadata_key VARCHAR(64) PRIMARY KEY,
    metadata_value VARCHAR(255) NOT NULL
);

INSERT INTO session_identity (session_id, sankalpa_id, identity_state)
SELECT p.id, p.sankalpa_id, 'ACTIVE'
FROM practice_session p
WHERE NOT EXISTS (
    SELECT 1 FROM session_identity i WHERE i.session_id = p.id
);
```

After schema creation, a startup initializer reads `service_instance_id`. If absent, it generates a
UUID and inserts it in a transaction; a concurrent insert collision is resolved by reading the
winner. It never overwrites an existing value. The application does not advertise readiness until
the value is readable and the ledger verifier succeeds. A database restored as the continuation
of the same service retains the value. An operator who forks a database into an independent
service must rotate the value before exposing that fork; deployment/runbook tests must cover this
because no application can infer whether a copied database is a replacement or a fork.

A startup verifier runs before the application accepts traffic and fails startup if a practice
session lacks an `ACTIVE` identity, owners disagree, an `ACTIVE` identity lacks its fact, or a
`DELETED` identity still has a fact. This catches an interrupted/manual migration and latent
corruption that table-local constraints cannot express.

Recommended constraints and indexes:

- primary key on `session_identity.session_id`;
- foreign key from `session_identity.sankalpa_id` to `sankalpa.id` with restricted deletion;
- existing primary key on `practice_session.id`;
- existing `(sankalpa_id, occurred_at)` read index;
- a consistency check in adapter integration tests that every active session has one `ACTIVE`
  ledger row and every `DELETED` row has no session fact.

### 5.3 Create decision table

Within one write transaction:

1. Require the target sankalpa and acquire its existing write lock/version ordering.
2. Read or claim the global identity.
3. Apply the table below.

| Identity state | Stored values | Result |
|---|---|---|
| Absent | — | Validate commitment/lifecycle, insert `ACTIVE` identity and session, return `created=true`. |
| `ACTIVE` | Same sankalpa and same `occurredAt` | Return the stored session with `created=false`; do not revalidate current lifecycle. |
| `ACTIVE` | Different sankalpa or `occurredAt` | `SESSION_IDENTITY_CONFLICT`. |
| `DELETED` | Same sankalpa | `SESSION_DELETED`; never recreate. |
| `DELETED` | Different sankalpa | `SESSION_IDENTITY_CONFLICT`. |

Two different IDs with the same `occurredAt` both follow the absent row and both succeed.

### 5.4 Delete decision table

Within one write transaction:

1. Require and order on the target sankalpa.
2. Read or claim the global identity.
3. Apply the table below.

| Identity state | Owner | Result |
|---|---|---|
| Absent | — | Insert `DELETED` identity; return success. |
| `ACTIVE` | Same sankalpa | Delete the session fact and change identity to `DELETED`; return success. |
| `DELETED` | Same sankalpa | Idempotent success. |
| Either | Different sankalpa | `SESSION_IDENTITY_CONFLICT`. |

This makes an unknown delete safe: it reserves the ID and is exactly what allows Undo to win when
the client cannot know whether a timed-out POST committed.

### 5.5 Transaction and concurrency rules

- Identity claim, domain validation, session insert/delete, and ledger transition are one database
  transaction.
- Same-sankalpa lifecycle and session commands retain the current parent ordering so a session
  cannot validate against a stale lifecycle.
- The ledger primary key serializes same-ID commands across different parents.
- A unique-key race while claiming `session_identity` rolls back and reruns the decision once
  against the winner's committed row. Only the recognized identity-key collision is retried; other
  integrity failures propagate.
- Reads may defensively join to `session_identity.state = 'ACTIVE'`, although deletion also
  physically removes the fact.
- No server-side retry creates a new `SessionId`.

### 5.6 HTTP contract

| Method and path | Request | Success | Documented non-success |
|---|---|---|---|
| `GET /api/v1/capabilities` | No body. | `200` with `sessionCommandIdentity: 1` and a stable `serviceInstanceId`. | Normal connectivity failures. |
| `POST /api/v1/sankalpas/{id}/sessions` | Supported clients send the same UUID as body `id` and `Idempotency-Key`, `occurredAt`, and the expected `Sankalpa-Service-Instance`; mismatches are invalid. | `201` for creation; `200` for exact replay. Both return the same session. | `400 INVALID_REQUEST`, `404 SANKALPA_NOT_FOUND`, `409 SESSION_IDENTITY_CONFLICT`, `409 SERVICE_INSTANCE_MISMATCH`, `410 SESSION_DELETED`, existing `422` domain refusals. |
| `DELETE /api/v1/sankalpas/{id}/sessions/{sessionId}` | Expected `Sankalpa-Service-Instance` header; no body. | `204` for first or repeated deletion, including delete-before-create. | `400 INVALID_REQUEST`, `404 SANKALPA_NOT_FOUND`, `409 SESSION_IDENTITY_CONFLICT`, `409 SERVICE_INSTANCE_MISMATCH`. |

The OpenAPI document describes the matching identity fields and first/replay status codes. Rollout
is explicitly staged:

1. Deploy the server first. It publishes `sessionCommandIdentity: 1`. During this compatibility
   phase it accepts old requests containing
   neither identity field and generates an ID exactly as the current server does. That legacy path
   does not claim retry safety.
2. Deploy the client that requires this capability before enabling log/delete commands and always
   sends both matching identity fields plus its expected service instance. The server requires and
   validates the instance header whenever a request supplies a client identity. Every action from
   this client has the required guarantee even while compatibility remains enabled.
3. After legacy clients are unsupported, require at least one identity field at the server boundary;
   keeping both in new-client requests remains the contract. The no-ID path is then removed and the
   OpenAPI fields are tightened in the same release.

The server resolves body/header identity in one parser: both and equal, either one alone, or the
temporary legacy fallback; both and unequal is always `400 INVALID_REQUEST`. If either identity
field is supplied, the service-instance header is mandatory. A value unequal to server metadata
returns `409 SERVICE_INSTANCE_MISMATCH` before any session or parent lookup. Requests with neither
identity field remain the temporary old-client path and do not claim retry safety.

The capability result is cached in the reliability journal. `serviceInstanceId` is the UUID in
`service_metadata`; it survives process restarts and address changes. A fresh database gets a new
value. A restored replacement intentionally retains it, while an independent database fork must
rotate it before serving traffic.

Offline logging is allowed only when that service instance previously advertised version 1 or
later. When a reachable service returns a missing/old capability and no work is pending, it
invalidates cached support, keeps reads available, and refuses logging/deletion with “Update the
Sankalpa service first.” When work is already pending, the old binding is retained for recovery but
nothing is sent to the incompatible service. A mere connectivity failure does not erase a
previously verified capability. Cached capability authorizes offline enqueue, while the
expected-instance header on every outbound mutation is the final guard against address reuse or a
server replacement between capability fetch and command handling. A response whose session ID
differs from the requested ID is a protocol violation: quarantine the operation, skip it on later
flushes, preserve it for recovery, and show a durable notice.

### 5.7 Server code impact

Expected changes stay inside existing boundaries:

- `SankalpaUseCases` and `TransactionalSankalpaUseCases`: accept `SessionId`, return
  `SessionLogResult`, add `deleteSession`.
- `SankalpaService`: implement the create/delete decision tables.
- `SessionRepository`: identity lookup/claim/transition, session lookup, and physical deletion.
- `JdbcSankalpaPersistenceAdapter`: ledger persistence and narrowly scoped collision retry support.
- `SankalpaController`/`ApiModels`: identity and expected-instance header parsing, replay status,
  DELETE endpoint.
- Capability response/controller and server metadata initializer: advertise identity version 1
  and the persistent service instance ID.
- `ApiExceptionHandler`: stable conflict and gone mappings.
- `schema.sql` plus an explicit idempotent backfill migration.

`Session` remains immutable and has no deleted flag. `Sankalpa.logSession` still owns eligibility
rules for a genuinely new session.

## 6. iOS Client Design

### 6.1 Durable operation journal

Replace the create-only outbox with one versioned envelope written atomically:

```swift
struct ReliabilityJournal: Codable {
    var schemaVersion: Int
    var serviceLocation: String
    var capability: ServiceCapability?
    var creates: [PendingSession]
    var deletions: [PendingSessionDeletion]
    var quarantinedCreates: [SessionId]
    var recentLogs: [RecentSessionLog]
    var notices: [String]
}
```

The concrete encoding uses separate create and delete arrays. Loading and every save validate that
session IDs are globally unique, quarantined IDs identify existing creates, every operation has a
service instance, and every operation matches the capability binding. Any duplicate or conflicting
operation makes the journal unreadable. The client never guesses or sends a destructive command
from contradictory data.

An unreadable journal puts session mutation into a recovery state. The unreadable file remains at
its active path, so every relaunch rediscovers the problem and cannot silently create an empty
journal. Reads from the last valid snapshot remain available, and all new log/delete commands and
automatic flushes are blocked so later writes cannot hide or overwrite the problem. The implemented
recovery action is an explicit, destructive discard with a warning; it atomically replaces the
preserved file and clears recovery only after that write succeeds.

Each create stores an immutable operation revision, session ID, sankalpa ID, performed-at,
logged/requested-at, and service instance. Each delete stores a newly generated operation revision,
session ID, sankalpa ID, performed-at display metadata, requested-at, and service instance.
Keeping performed-at on both operation kinds lets Pending Changes remain intelligible even when
the cache cannot be read.

Journal rules:

- the main-actor service owns every read-modify-write transition and publishes a journal only after
  its atomic file replacement succeeds;
- cached domain rules are checked before enqueue; create and its recent guard are persisted
  together before the first POST;
- a journal write failure sends no network command and returns a storage rejection;
- Undo/delete atomically replaces create with delete;
- deletion is sent only after its delete operation is durable;
- an operation is removed only after accepted state is durably applied to the cache and a
  compare-and-set proves that the journal still contains the exact operation revision that sent
  the request;
- a create refusal conditionally removes the exact current operation revision and its recent guard,
  and appends a durable notice in the same journal write;
- a delete refusal conditionally removes that exact revision, restores the unchanged server
  snapshot to visibility, and appends a durable notice in the same write;
- a notice is removed only after the UI acknowledges it;
- writes use atomic replacement and report failure; unreadable bytes are preserved rather than
  overwritten;
- operations are scoped to `serviceInstanceId` and are never sent to a different server instance.

The pre-request recent guard protects a crash between enqueue and response. Its `acceptedAt` value
is renewed on service acceptance or an indeterminate result. If the process dies first, the initial
durable timestamp remains the conservative start of the confirmation window on relaunch.

The reliability journal stores the last compatible capability and service instance. A practice
cache written before these fields existed may still be used for reads, but it cannot authorize
offline session mutation until the service is contacted and the journal is upgraded.

The service-settings flow takes the conservative rule: while any create or delete is pending,
relocation is refused. With no pending operations, the location changes and its capability becomes
the new journal binding when reached. `RemoteSankalpaService` enforces the same precondition so a
non-UI caller cannot bypass it. Silently retargeting operations is forbidden.

### 6.2 Legacy outbox recovery

The old outbox did not record a trustworthy service instance, and its local ID was not the ID used
by the old server. Automatically importing or value-matching those entries could either duplicate
a session or silently merge an intentional repeat. The decoder therefore recognizes the old array,
leaves its bytes untouched, enters reliability recovery, and sends nothing. The user can keep the
file for external recovery or explicitly discard it after a destructive warning. All operations
created by this version reconcile only by UUID.

### 6.3 Snapshot overlay

`SnapshotStore` keeps the last server snapshot as a base and derives visible state:

```text
visible sessions = (server sessions union pending creates by ID) minus pending deletes by ID
```

The same visible collection supplies history, lifetime totals, current/open period progress,
closed period outcomes, missed counts, and journal entries. Once complete history is available,
the cache no longer persists independent server counts; totals are derived from the visible
sessions so there is no second count path that can forget deletion suppressions.

Rules for server-accepted commands:

- On accepted create, upsert the returned session into the cached base and persist it. Then remove
  the create only if its operation revision is still current. If Undo replaced it while the POST
  was in flight, retain the delete and its suppression; the accepted fact may exist in the base but
  remains invisible until DELETE settles. If the app stops between writes, the remaining operation
  retries safely.
- On accepted delete, remove the session from the cached base, persist it, then remove the
  delete only if its operation revision is still current. A failed follow-up refresh cannot
  resurrect it.
- If a `2xx` result cannot be persisted into the base snapshot, do not remove the operation. Leave
  the original operation untouched and replay it safely later; the server returns the same result
  through idempotency.
- On rejected create, remove its overlay and add a notice only if that create revision is still
  current. A newer delete is retained and sent, preserving delete-before-create protection.
- On a definitive delete refusal, conditionally remove the suppression for that exact revision and
  persist a notice. The immutable session in the unchanged server snapshot becomes visible again;
  the surrounding synchronization then performs its normal complete refresh.
- A `SESSION_DELETED` response to an ordinary pending create is a rejection and produces a notice.
  A local Undo never leaves a create operation to receive that response; it has already become a
  delete operation.

### 6.4 Synchronization algorithm

All interactive sends, refreshes, and journal flushes run on the main-actor service. Network awaits
can re-enter it, so correctness never relies on actor call ordering alone: each request captures the
service instance, session ID, and operation revision, and every response uses the conditional rules
above. A refresh also captures a publication revision. Starting a newer refresh or accepting a
local create/delete rotates that revision, preventing an older read from replacing the newer base
snapshot. Concurrent refresh triggers may still duplicate read work, but only the newest eligible
publication can change local state.

An interactive command does not wait for a complete history refresh before reporting its result.
After a POST/DELETE response, it applies the accepted mutation durably, returns the disposition so
the UI can show Accepted/Pending and Undo, then rebuilds from the updated overlay. A background sync
uses the complete sequence below.

Order on launch, foregrounding, connectivity restoration, pull-to-refresh, scheduled retry while
the app is active, and after a reachable command:

1. Load and validate the journal.
2. Stop session delivery in recovery mode if the journal is corrupt or legacy.
3. Verify or load the cached capability for this exact service instance; send nothing if it is
   unsupported or the instance ID differs. Include that expected instance in every mutation.
4. Flush deletes first.
5. Flush creates oldest first, skipping explicitly quarantined protocol violations.
6. Stop a queue after an unreachable response; later operations remain durable.
7. Refresh the complete server snapshot and capability.
8. Reapply remaining operation overlays.
9. Publish durable reconciliation notices.

The validated journal cannot contain create and delete for one ID. DELETE is still flushed before
POST so independent corrections are settled before new logging work.

Response classification is explicit:

| Response class | Client treatment |
|---|---|
| POST `200`/`201` with a valid matching representation, or DELETE `204` | Accept and apply durably. |
| Recognized, well-formed stable problem (`INVALID_REQUEST`, `SANKALPA_NOT_FOUND`, domain refusal, `SESSION_IDENTITY_CONFLICT`, `SESSION_DELETED`) | Definitive rejection: correct overlay and add one notice. |
| `409 SERVICE_INSTANCE_MISMATCH` | Preserve all operations, stop the flush, and enter service-binding recovery; do not treat the command as rejected. |
| `409 CONCURRENT_MODIFICATION` | Keep pending and retry on the next synchronization using the same identity. |
| Connection failure, timeout, `408`, `429`, `5xx`, empty/malformed success, or unknown response | Indeterminate: keep pending and stop this flush; never turn it into a rejection. |
| Advertised identity protocol returns a different session ID | Quarantine as a protocol violation, stop the flush, and do not retry automatically. |

Only a definitive rejection creates a reconciliation notice. Retriable/indeterminate attempts keep
the existing operation and do not create duplicate notices.

The stable-problem row is command-specific. It removes a refused create locally. A definitive
DELETE refusal removes its suppression and restores the unchanged cached server fact while leaving
a durable notice; the normal sync refresh confirms server truth. `SERVICE_INSTANCE_MISMATCH` is
never a rejection.

Retry scheduling uses a bounded 30-second cadence while the app is active and also runs at launch,
foregrounding, and manual refresh. It never changes the operation identity. Mobile suspension can
defer execution; the next available trigger resumes the same journal. This is what makes a pending
deletion complete without requiring a second deletion action once connectivity is available.

Service-binding recovery preserves the old snapshot and overlays and identifies the expected
destination. The user may correct the address back to the originating service after pending work
is resolved. The client never transfers operations to a reached replacement merely because the
former service is unavailable.

### 6.5 Complete history

The current ten-page cap and 3,650-day query cannot satisfy “delete any logged session later.”

- `allSessions` follows the first page's `totalPages` until its declared `totalElements` are read.
- It validates page number/size, deduplicates only by identical session ID, and requires the final
  unique count to equal the first page's total. A changing/duplicate/incomplete page set is retried
  once from page zero; a second inconsistency fails refresh and preserves the previous complete
  snapshot. It never publishes truncated history.
- `SessionHistoryView` uses the full visible session collection, not the reporting-day range.
- Period and journal reporting may remain range-bounded, but deletion of a session forces their
  visible calculations to use the same overlaid session set for the ranges they display.

If history size later becomes a memory concern, replace this with a paginated history repository;
do not reintroduce an invisible cap.

### 6.6 Command dispositions and receipts

The storage layer returns an explicit outcome rather than `nil` for every success:

```swift
enum SessionCommandDisposition {
    case acceptedByService(SessionReceipt)
    case pendingOnDevice(SessionReceipt)
    case rejected(SankalpaCommandError)
}

struct SessionReceipt {
    let sessionId: SessionId
    let sankalpaId: SankalpaId
    let occurredAt: CalendarMoment
}
```

Delete has corresponding `removed`, `pendingOnDevice`, and `rejected` results. The exact receipt is
the target for Undo; no “latest session” lookup is allowed.

### 6.7 Processing and repeat confirmation

`AppModel` owns the interaction policy because logging is reachable from Today, detail, and the
past-session form.

- A per-sankalpa in-flight set disables every logging entry point while one action is processing.
- A log proposal checks the durable recent-log guard before creating an ID or writing an operation.
- If the newest completed/durable-pending action for that sankalpa is less than 60 seconds old, the
  proposal waits for confirmation.
- Cancel discards the proposal and changes no state.
- Confirm generates a fresh ID and executes once. It never reuses the preceding action's ID.
- The proposal preserves the chosen performed-at value, including an identical timestamp.
- Recent guards are keyed by session ID, bounded to the newest 64 entries, ignored after 60 seconds,
  removed by accepted deletion, and temporarily suppressed by pending deletion. Their timestamp is
  renewed when the service accepts or an indeterminate request becomes pending.
- Use an injected wall-clock date source for the 60-second duration; a monotonic clock cannot
  survive relaunch and `CalendarMoment` is not an elapsed-time clock.

### 6.8 User-visible states

| State | Required presentation behavior |
|---|---|
| Processing | Disable all log controls for the sankalpa and show progress. |
| Accepted | Show “Session logged” and an Undo action bound to the receipt. |
| Pending | Show “Session saved — waiting to send” and the same Undo action; show the persistent pending summary. |
| Rejected immediately | Keep the form/action context, show the refusal, and add no session. |
| Pending create later rejected | Remove it from all calculations and present its durable notice. |
| Pending delete | Hide it from all calculations; show a persistent summary and a Pending Changes surface identifying the session, performed-at time, and destination service. |
| Reliability recovery | Keep the last valid snapshot readable, block session mutations and automatic delivery, identify the preserved problem, and require an explicit recovery or discard decision. |
| Pending delete later rejected | Restore it everywhere and present its durable notice. |

Every history row exposes permanent deletion through an accessible action and confirmation. The
confirmation states that totals and past period outcomes may change. Undo is an immediate
convenience; the same permanent delete remains available without a time limit.

Pending Changes lists every unresolved create and delete using journal data, including operation
kind, performed-at time, and destination service. It also identifies quarantined creates that need
attention. Pending deletes stay absent from normal history and calculations.

## 7. Failure And Race Matrix

| Situation | Required final state |
|---|---|
| POST commits, response is lost, retry arrives | One active session; retry returns it. |
| User taps twice before first action resolves | Second submission is blocked; one identity exists. |
| User logs again within one minute and cancels | No new identity or operation. |
| User confirms a rapid repeat | New identity; second legitimate session. |
| Two confirmed sessions have identical performed-at | Both active and counted. |
| App crashes after journaling create but before POST | Relaunch shows pending and retries same ID. |
| App crashes after accepted create is cached but before operation removal | Relaunch may retry; server replays; display deduplicates by ID. |
| Undo replaces create while POST is in flight | Late POST may update the base, but cannot remove the newer delete; suppression remains and DELETE follows. |
| Offline create is undone | Journal contains delete only; no later create can appear. |
| DELETE commits, response is lost | Session stays suppressed; retry returns 204. |
| App crashes after accepted delete is cached but before operation removal | Session stays absent; DELETE safely retries. |
| Refresh returns a session whose deletion is pending | Overlay keeps it hidden. |
| Follow-up refresh fails after accepted create/delete | Durable cached mutation preserves the accepted state. |
| Server accepts but base-cache persistence fails | Journal operation remains; client finishes the local commit or safely replays the same command. |
| Server rejects queued create | Pending session disappears, calculations reverse, notice persists. |
| Server rejects queued delete | Exact suppression is removed, unchanged cached truth reappears, and the durable notice is published; normal refresh confirms it. |
| Create races delete for same ID and parent | Ledger orders them; if delete wins, create receives deleted. |
| Same ID is used across different parents | One owner wins; other command conflicts. |
| User requests a service-address change with pending work | Relocation is refused; the journal and destination remain unchanged. |
| Address resolves to a different/replaced service instance | Pending operations remain bound to the old instance and no mutation is sent. |
| Address changes instances after capability verification | Expected-instance header makes the new server reject before mutation; pending work enters binding recovery. |
| New client reaches an old/incompatible server | Reads remain available; no session command is sent; update notice is shown. |
| Server advertises identity support but returns another ID | Operation is quarantined and not automatically retried; durable protocol notice is shown. |

## 8. Test Design

### 8.1 Server

Automated coverage includes:

- Exact replay returns the same ID and original `loggedAt`, with `created=false`, even after a
  lifecycle change.
- Same ID with changed parent or performed-at returns `SESSION_IDENTITY_CONFLICT`.
- Different IDs with identical performed-at create and count two sessions.
- Delete active, delete twice, delete-before-create, and delayed create after delete.
- Deleted sessions leave history, totals, open/closed outcomes, and missed arithmetic.
- Two simultaneous identical creates produce one fact and one replay.
- Create/delete and cross-parent create/delete races preserve exactly one ledger owner/state.
- Capability, OpenAPI, and controller tests cover identity negotiation, matching identity fields,
  mandatory expected-instance header, pre-mutation instance mismatch, 201/200/204, 409, and 410.
- Production-driver SQLite tests and H2 integration tests exercise the schema and persistence
  adapter; startup verifies every active/deleted ledger row against its session fact.

### 8.2 iOS storage and application

Automated coverage includes:

- Journal durability, fail-closed duplicate/corruption handling, and service-instance scoping.
- Corrupt journal recovery preserves the original bytes, blocks mutations/flush, and never creates
  an empty replacement without an explicit warned discard.
- An old-format outbox is preserved, blocks mutation, and is replaced only through warned discard.
- Missing/old capability sends no create/delete; cached compatible capability permits offline
  enqueue only for its original service.
- Every mutation carries the journal's expected instance; an address-reuse mismatch keeps the
  operation and changes no data on the reached server.
- Request body and header use the same durable session ID on first attempt and every retry; the
  server rejects a mismatch.
- Late create/rejection responses cannot consume a newer delete operation; stale refreshes cannot
  publish after service rebinding, a newer refresh, or an accepted local create/delete.
- Pending create counts immediately and survives relaunch.
- Undo atomically becomes delete and never sends a later POST.
- Pending delete suppresses history, total, open/closed outcomes, missed counts, and recent guard.
- Accepted create/delete survives failed refresh and relaunch.
- A `2xx` followed by cache-write failure never removes the operation and converges by local retry
  or idempotent command replay.
- Rejected create and delete correct locally and produce a durable, explicitly acknowledged notice;
  if that correction cannot be persisted, the operation remains pending instead of reporting a
  false rejection.
- Timeout, 5xx, malformed success, and exhausted transient-conflict retry keep the operation and
  never emit a false rejection.
- Legacy entries send nothing; current same-time sessions remain distinct by UUID.
- Synchronization flushes deletion before creation and conditions responses on operation revision.
- Connectivity restoration and scheduled active-app retry resume the same pending identities
  without manual resubmission.
- All session pages are read and an older-page session can be deleted.
- Recent guard persists, expires at 60 seconds, is per sankalpa, and is restored after rejected
  deletion when still current.

### 8.3 UI journeys

Simulator journeys prove:

1. first log shows processing, then accepted/Undo;
2. rapid second log asks for confirmation;
3. cancel leaves the count unchanged;
4. confirm produces a legitimate second session;
5. Undo removes that exact session;
6. complete history exposes permanent deletion;
7. deletion confirmation removes the remaining session and updates totals/history;
8. offline logging remains visible as pending;
9. existing lifecycle, history, accessibility-size, dark-mode, and recovery flows still work.

Accessibility assertions cover descriptive labels for Undo, delete, pending status, and confirmation
actions. Unit tests cover state transitions; UI tests do not attempt to manufacture network races.

## 9. Implementation Order

1. Add the server identity ledger migration and repository primitives.
2. Implement server create replay/delete decision tables and concurrency tests.
3. Publish and verify the capability and HTTP/OpenAPI contract.
4. Add client capability negotiation, then introduce the reliability journal and fail-closed
   recovery for the legacy outbox.
5. Rebuild snapshot overlay and serialized synchronization around the journal.
6. Add explicit dispositions, receipts, recent guard, and shared AppModel coordination.
7. Add Undo, complete-history deletion, and pending/rejection presentation.
8. Run backend, Swift package, simulator, race, and relaunch tests.

Each step must leave existing lifecycle and period tests green. Do not start UI work until the
storage state machine is proven by tests.

## 10. Definition Of Done

Implementation is complete only when:

- every invariant in section 3 is backed by an automated test;
- server migrations work against both an empty database and a populated current-branch database;
- no current operation is reconciled by performed-at value;
- no pending operation can cross service instances, even when an address is reused;
- corrupt or unbound legacy journal state fails closed without losing its original bytes;
- every asynchronous response is conditionally applied to the operation/service revision that sent
  it;
- every log entry point uses the same processing/repeat policy;
- history has no silent page or age truncation;
- accepted mutations survive failed refresh and process restart;
- rejected pending mutations both correct the display and leave an acknowledgeable notice;
- deletion changes open and closed period calculations consistently on server and client;
- the full existing backend, Swift package, and iOS UI suites pass.
