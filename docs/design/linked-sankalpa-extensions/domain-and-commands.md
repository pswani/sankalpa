# Domain and Commands

## Domain changes

| Type | Change | Rule |
|---|---|---|
| `Sankalpa` | `seriesId: SankalpaId` | Original ID for every member; an unrelated declaration uses its own ID. |
| `Sankalpa` | `extensionOf: Optional<SankalpaId>` | Immediate source, absent on an original; immutable. |
| `Sankalpa` | Existing `declaredAt` | Creation time of this vow, not the inherited declaration time. |
| `LifecycleTransition` | `originSankalpaId: SankalpaId` | Vow on which the user performed the original transition. |
| `Session` | Existing `sankalpaId` | Immutable logging owner; not necessarily the displayed or only contributing vow. |

Retain all other commitment fields, session identities, timestamps, lifecycle states, and period
outcome rules. `seriesId` is an existing vow ID, so no new identity namespace is needed.
Reconstitution accepts the new fields after collection-level validation. It does not invoke the
declaration factory or apply today's start-date limit to historical records.

### Extension factory

Add `source.extend(newId, totalPeriodCount, now)` in Java and both Swift cores:

```text
require source.state in {In progress, Paused}
require source.periodCount exists
validate totalPeriodCount with existing whole-period bounds
require totalPeriodCount > source.periodCount
newCommitment = source.commitment with periodCount = totalPeriodCount
require newCommitment.endDate >= date(now)
return a new vow:
  id = newId; declaredAt = now
  seriesId = source.seriesId; extensionOf = source.id
  practice fields = source practice fields
  commitment = newCommitment
  lifecycle = independent value copy of source.lifecycle
```

The source is unchanged. Do not call `declare`, generate Begin, shift period boundaries, or load
sessions. Retain the existing adapter's title and duration limits rather than broadening them
during this feature. The immediate source must be extendable; a terminal ancestor/root is valid.
The application rejects `newId == source.id` or reuse of any existing unrelated vow identity.

The source's copied history is complete at the transaction boundary, including paused intervals.
Copied entries retain origin and timestamps. New transitions use the receiving vow's ID as origin.
An extension inherits its initial Begin and cannot Begin a second time. Own Pause/Resume/Complete/
Stop operations have no effect on other members, including ancestors.

### Eligibility and contribution

Extract `acceptsPerformedAt(at)` from the existing logging checks:

```text
acceptsPerformedAt(vow, at) =
  vow.commitment.covers(date(at)) AND vow.lifecycle.wasInProgressAt(at)

contributes(session, target, ownersById) =
  ownersById[session.sankalpaId].seriesId == target.seriesId
  AND target.acceptsPerformedAt(session.occurredAt)
```

Missing owner/membership is invalid input to a contribution calculation, not an unrelated series
or a silent exclusion. The application resolves membership; the aggregate owns eligibility.
`logSession` still rejects future performed times and validates the requested owner before creating
one fact. Reads do not use `logSession`: it generates a fact and checks the current clock.

Implement `SessionContributions` as a small application helper, reused by histories, lifetime
counts, summary/detail progress, contributor lists, and outcomes. It takes a consistent set of
owners, target timelines, and active candidates; it does not fetch repositories per session.
Load series members once per query. The client uses the same domain predicate on its overlaid set.

For one vow, count unique contributing `SessionId`s. For a journal or selected set of vows, take
the union of fact identities, never the sum of per-vow counts. Keep distinct confirmed identities
even when times match. Feed filtered facts to the unchanged outcome calculator, expanding reads
to the full selected period boundaries first. A terminal cutoff may exclude a partial period
while history still shows eligible sessions within it.

## Port changes

Extend the existing ports with these conceptual operations; signatures can retain the current
Java/Swift error conventions:

```text
SankalpaRepository:
  find(id), findDirectExtension(sourceId), findSeriesMembers(rootId)
  acquireSeriesWriteGuard(rootId), reloadForUpdate(id), save(vow)

SessionRepository:
  existing identity/create/delete operations, unchanged owners
  scanSeriesCandidates(rootId, range, after, chunkSize)
  scanUniqueFacts(range?, after, chunkSize)

PracticeReadMetadata (methods on the existing read/persistence boundary):
  readRevision(), incrementRevision()
```

The revision is adapter/application coordination, not a domain field. Do not add a generic
unit-of-work or locking service. The existing transaction wrapper controls commit and retries.
Owner-only repository reads may remain for legacy single-vow requests; feature queries must
call the contribution helper.

Add an explicit application-level `PracticeContract` argument (`SINGLE_VOW_V1` or `LINKED_V1`)
to affected use cases. Web/conversation adapters derive it from the request; domain objects never
see HTTP headers. Do not default internal calls to linked support, because that would bypass
the requesting client's confirmation/read restrictions. The adapter verifies service identity,
and the application checks membership-dependent contract support under the root guard.
`LinkedContractRequired` is an application exception, not a `DomainException`; the existing
conversation handler's domain-refusal catch must not resolve a proposal on this exception.


## Extension command

Input: source ID, stable extension ID, requested total period count, expected service instance,
and linked contract version. Request syntax/identity-header validation precedes execution.

```text
in one adapter-managed write transaction:
  verify expected service identity and linked contract
  locate source's immutable root; acquire its write guard
  reload source and resolve extensionId
  if extensionId already exists:
    if extensionOf == sourceId AND periodCount == requested count:
      return existing authoritative vow, created = false
    otherwise: ExtensionIdentityConflict
  if source has a direct child: ExtensionAlreadyExists(childId)
  now = clock.now()                  // after write guard
  child = source.extend(extensionId, requested count, now)
  save child and its entire copied timeline
  increment practice revision
  commit; return child, created = true
```

Exact replay returns current authoritative state for that child, including any subsequent lifecycle
changes, but preserves the same identity, original creation time, immutable commitment, and link.
It precedes source-state validation; completion after the original creation cannot invalidate retry.
No separate extension identity ledger is needed because vows/links cannot be edited or deleted.
An existing-child conflict includes the authoritative child ID so the client can resolve its attempt.

Extension-ID uniqueness across different roots still needs the database primary key. A recognized
source-child or identity collision rolls back and reruns the decision against the winning row.
Do not reinterpret foreign-key failures or malformed history as a replay conflict.

## Session and lifecycle commands

For every new session, lifecycle mutation, or delete, locate the requested vow's root and acquire
that guard before reading mutable timelines, checking whether the series has multiple members,
and capturing command time. Checking linked membership only in the controller creates a race:
an extension can commit between the version check and the session write.

Keep the existing session identity decision table:

| Ledger state | Log command | Delete command |
|---|---|---|
| Absent | Require contract, validate owner, claim ACTIVE, save one fact. | Require contract, claim DELETED for requested owner. |
| ACTIVE, same owner | Exact performed time replays; changed time conflicts. | Require contract, remove fact and mark DELETED. |
| DELETED, same owner | Report permanently deleted; never recreate. | Replay deletion successfully. |
| Present, different owner | Conflict. | Conflict. |

Resolve nonmutating same-owner replays under the existing identity-v1 contract even after linking.
New writes on multi-member series need linked version 1. An unsupported-version refusal keeps
client work unresolved; it must not be treated as a permanent session business rejection.
Deletion uses the immutable logging owner exposed by the selected row, not the viewed vow.
Deletion does not check performed-time eligibility and cannot reopen a completed vow.

Increment the practice revision only on actual changes: new session, first deletion reservation/
removal, declaration, extension, or lifecycle transition. Exact replay/repeated delete does not
increment it. Revision increment and the changed fact commit together. No session write fans out
to contributing vows, and no count/achievement write follows deletion.

## Ordering and rollback

Relational write order is root guard → affected vow/identity → practice revision metadata last.
All mutation entry points follow it, including deletion of an absent session. Different-root
identity collisions are resolved through the one global identity primary key. Use the existing
transaction retry boundary; every retry starts a fresh transaction and reloads state. Bound
recognized contention retries to three total attempts; exhausted transient contention is a
retryable service failure, not a business rejection. Do not retry arbitrary integrity failures.

For SQLite, acquire the write reservation before dependent reads. The existing JDBC guard uses
`UPDATE sankalpa SET version = version WHERE id = ?`; adapt it to the root. A prior deferred read
may prevent lock upgrade under contention: roll back and retry the whole operation, never continue
with its old snapshot. Row-locking test adapters lock the root and reload the target. Locking must
not change the root's domain version or manufacture an audit entry. Preserve existing optimistic
version checks on actual lifecycle saves.

File-backed mutation runs serially on the existing owning actor/main thread with no suspension
between validation and atomic commit. Build a candidate collection, validate it, write successfully,
then replace in-memory state. Write failure retains both the original source and the prior collection.

### Conversation path

Keep extension creation manual in this release. Existing session proposals retain their selected
owner and stable session ID. Before a linked proposal/confirmation, verify the requesting client's
linked version and present affected vows. Revalidate under the root guard at confirmation. A
proposal prepared before linking is still about its original owner; upgrade-required leaves it
pending instead of marking it rejected/executed. Old collection/context requests must not bypass
linked read restrictions. The server's tool allowlist gains no extension tool.

Use proposal row → series root → identity → revision as the conversation lock order. Manual
commands never lock proposal rows, and no series mutation queries/locks a proposal after obtaining
the root. This prevents a reverse-order deadlock while preserving the existing atomic proposal
confirmation/session write. Contract refusals occur before resolving the proposal.

The repository currently injects the raw `SankalpaService` into `ProposalService`, with the
conversation wrapper owning the outer transaction. Preserve that arrangement. Put bounded
contention/identity retry around the entire confirmation transaction, not around only the joined
session command: retry must reload both proposal and practice state without a rollback-only
outer transaction or a prematurely resolved proposal.

## Local-file command parity

The local-file service currently has narrow Undo and owner-only queries. Completing this feature
there also requires its permanent shared-session deletion action and series-scoped repeat guard;
do not leave those requirements conditional on the remote adapter. Pass a stable session ID
from each logging action into the local service. Replay an exact existing same-owner/time fact
before rechecking lifecycle; conflicting reuse must not be silently ignored by `FileStore.save`.

Local logging/deletion and recent-guard changes commit in the same candidate snapshot. Undo binds
to the exact identity, and later deletion is available from any contributing history using that
fact's owner. There are no remote pending commands in this adapter; serialized synchronous commits
avoid a delayed network create, so a server-style identity ledger is not added to the local store.

