# 11 — Linked Sankalpa Extensions

This is the target architecture for
[Linked Sankalpa Extensions](../../requirements/linked-sankalpa-extensions.md).
It extends the existing architecture; it is not a claim that the feature is implemented.

## Model and boundaries

Each vow remains a `Sankalpa` aggregate with its own commitment and lifecycle. A linked series
is an immutable membership relationship, not an aggregate containing all vows and sessions.
There is no session-copy operation, applicability table, activity catalogue, or event consumer.

```text
Sankalpa
  id
  seriesId              original sankalpa's ID; self for an unrelated declaration
  extensionOf           optional immediate source ID
  declaredAt            creation time, including for extensions
  commitment            original start/period/frequency, own duration
  lifecycle             own timeline, with inherited transition provenance

Session
  id
  sankalpaId            immutable logging owner, not the only contributing vow
  occurredAt
  loggedAt

LifecycleTransition
  from, to, effectiveAt, recordedAt
  originSankalpaId      vow on which the user originally performed this transition
```

The existing `sankalpaId` on sessions and the identity ledger retains its meaning as command
owner. Linking does not transfer identities or make another owner an exact replay. Series
membership is resolved through the logging owner; sessions need no second series identifier.
Each root is retained even after completion or stopping because sankalpa deletion is out of scope.

`seriesId`, `extensionOf`, and inherited history are set only by declaration or extension.
An original has `seriesId == id` and no `extensionOf`. An extension has its source's `seriesId`.
Each source has at most one direct child. Strictly increasing durations, existing same-series
parents, and immutable links form a linear series without cycles or branches.
Membership is not a lifecycle command: linking to a completed root is valid when the immediate
source being extended is itself In progress or Paused.

## Domain behavior

Add `Sankalpa.extend(newId, totalPeriodCount, now)` as a creation factory on the source. It:

1. Requires a finite source in In progress or Paused.
2. Requires a greater total period count and a derived end date on or after `now`'s date.
3. Copies title, description, action type, start date, period unit, and frequency.
4. Sets the new ID, source link, series ID, creation time, and longer commitment.
5. Takes a value copy of the source's entire lifecycle timeline at creation.

The application checks whether the source already has a child. The factory does not load
repositories or sessions. It does not call `declare`: the one-year backdated-start restriction
applies to unrelated declarations, not to an inherited start date. Existing period-count limits
and calendar rules still apply. Domain refusals include `SourceNotExtendable`,
`DurationNotGreater`, and `ExtensionEndsInPast`; `ExtensionAlreadyExists` is an application refusal.

Every new user lifecycle transition records its own vow's ID as `originSankalpaId`. Copying
history retains the original origin and both original timestamps, including through repeated
extensions. Audit rows can therefore identify inherited transitions without pretending the user
performed them on the new vow. Extension creation is shown separately from lifecycle transitions;
it is not a fabricated Begin or Resume. A copied timeline is independent, so later changes to
either vow affect only that vow. An extension already inherits Begin and cannot Begin again.
On restore, inherited entries must form an exact initial prefix of the immediate source's
timeline, retaining all entry values. Their origins must belong to ancestors of the extension;
the remaining entries must originate on the extension and be recorded no earlier than creation.
Do not compare the extension to the source's entire current timeline: the two can diverge after
creation. The inherited prefix ends where entries with the extension's own origin begin, or at
the end if it has no new transitions. That prefix must include the source entries strictly before
creation; entries with equal timestamps are ordered by their persisted sequence and inherited
prefix, rather than guessed from timestamp equality alone.

Extract the existing coverage/lifecycle checks into a domain predicate:

```text
Sankalpa.acceptsPerformedAt(at) =
  commitment.covers(at.date) AND lifecycle.wasInProgressAt(at)
```

`logSession` additionally rejects future performed times and supplies the owner and log time.
Reads use the same predicate rather than manufacturing a new session or applying current-state
logging rules. Completed and stopped vows can still accept contributions from eligible past times.

## Contributions are derived

For target vow `v` and active session `s`:

```text
contributes(s, v) =
  seriesOf(s.sankalpaId) == v.seriesId AND v.acceptsPerformedAt(s.occurredAt)
```

The application resolves membership; the domain supplies performed-time eligibility. No titles,
action types, or overlapping dates are used to infer relationships.

For one vow, fetch active session candidates from its series in the requested date range and
filter with this predicate. Deduplicate by `SessionId`, never by performed time. Every history,
count, and outcome query uses this same contributing set, including lifetime counts. The
outcome calculator remains unchanged: it receives the target's commitment, timeline, and filtered
sessions. Its terminal cutoff can omit a window while session history still shows eligible facts.

The journal and totals across vows use a union of session IDs, not a sum of per-vow counts.
Candidate reads for the journal are paginated and include each fact once. Resolve a session's
contributing vows from its series with the same predicate to explain sharing and deletion.
Pagination of per-vow history occurs after eligibility filtering; filtering a candidate page
cannot be mistaken for the end of the history. Lifetime counts traverse the full contributing
set or use an equivalent complete bounded traversal, not the currently displayed page.
Series membership, target timelines, and candidate facts for a contribution result come from
one consistent read snapshot. Detail/list counts are assembled through the contribution helper,
not read from owner-only aggregate counts. Candidate paging can scan incrementally while filling
an eligible page; it preserves a deterministic `(occurredAt, SessionId)` cursor. It never expands
an individual session into duplicate facts merely because several vows count it.

Future lifecycle commands cannot backdate a Pause or terminal transition. Existing timelines
are not rewritten, and links cannot be removed. Thus existing contributions do not require
stored assignments or reconciliation when later lifecycle commands occur. A new extension
adds a new view of the existing series facts immediately, including delayed logs and pending
logs once accepted. An unrelated sankalpa is simply a one-member series.

## Commands and transaction ordering

`ExtendSankalpa(sourceId, extensionId, totalPeriodCount)` uses a stable client-created extension
ID. In one transaction, resolve an existing exact result first; otherwise read a consistent source,
check absence of a child, invoke the factory, and persist the new vow with its copied history.
An exact retry matches ID, source, and requested total period count and returns the existing vow
even if the source has since completed. Reusing an ID with other values conflicts. A different
ID against a source with an existing child reports that child; it never creates another branch.
The stored extension is sufficient replay evidence because links and commitments are immutable.

Extension, lifecycle changes, and new session commands acquire the same series-root write guard
before reading the lifecycle snapshot and obtaining the command's `now`. This gives overlapping
operations one order and prevents creation from copying an uncommitted source timeline. The
guard is the existing original sankalpa row, not a new series aggregate or lock table. Resolve
its ID through immutable membership, then reload affected vows under the guard. SQLite uses its
write transaction boundary; a row-locking adapter can lock the root. File-backed adapters serialize
the equivalent mutation and atomically save the complete result. No network await occurs inside
that local mutation boundary.

The session identity ledger still orders same-ID commands globally, including attempts naming
unrelated vows. Keep a consistent root-then-identity lock order for writes; recognized uniqueness
conflicts roll back and re-evaluate the winner. Exact replay does not revalidate eligibility.
Delete-before-create still reserves the original owner and permanently blocks delayed creation.
An extension reads no session history, so creation cannot race with session copying or deletion.

The unique direct-source constraint is the final guard against concurrent branches. Extension
ID conflicts and source-child conflicts are distinguished from unrelated persistence errors.
Creation, history copy, and membership are all-or-nothing; no partially created extension is visible.
For deletion, resolve the requested owner's immutable root and take the same root-then-identity
order even when the session is absent. This keeps the ledger race policy compatible with every
write path. Read-only replay still returns the existing immutable command result without calling
the creation factory again.

## Deleting from a linked vow

Keep `DeleteSession(ownerId, sessionId)` and its existing owner-based identity contract. Every
session read row and receipt exposes both `sessionId` and `loggingSankalpaId`. A deletion initiated
from another contributing vow routes to that logging owner. It does not substitute the displayed
vow ID. This preserves repeated delete, delete-before-create, cross-owner conflict handling,
and minimal deleted ledger rows without another membership or tombstone protocol.

The confirmation lists affected vows. Deleting removes the one fact, so every contributing view
and outcome loses it. Completion states remain user-declared and unchanged. Undo also uses the
original receipt, including when navigation changes the displayed vow.

## Application ports and transport

Extend existing ports rather than adding a series repository:

| Boundary | Additions or changed semantics |
|---|---|
| `SankalpaRepository` | Find direct child; load series members; acquire root write guard. |
| `SessionRepository` | Range-bounded active series candidates; paginated unique journal facts. |
| Session contribution helper | Resolve series membership and call the target's domain eligibility predicate. |
| `SankalpaReadPort` | Source/child navigation, series membership, lifecycle provenance, distinct successful vows. |
| Session read models | Immutable logging owner and eligible contributing vow IDs. |
| Detail/summary read models | Own duration, state, end date; application assembles contributing count. |

`POST /sankalpas/{sourceId}/extensions` carries `id` and `totalPeriodCount`, with matching
`Idempotency-Key` and expected service instance. New creation returns `201`, exact replay `200`,
identity or existing-child conflict `409`, and invalid extension parameters a business refusal.
Existing reads expose links and provenance; no link-editing endpoints are introduced.
`GET /sankalpas/{id}/linked-series` supplies the series view; `GET /sessions?from=...&until=...`
supplies unique journal facts with cursor pagination. Read rows that were previously labelled
simply `sankalpaId` additionally expose that same value as `loggingSankalpaId` to avoid confusing
it with the viewed vow. Keep the old field as a compatibility alias, not a second owner.
Unrelated-vow session rows also expose their logging owner.

Advertise `linkedSankalpaExtensions: 1` alongside `sessionCommandIdentity: 1`. The new capability
means series-aware reads, owner-bearing session rows, extension identity/replay, and shared
deletion semantics are available together. Updated clients never interpret old per-owner counts
as linked-vow counts. Servers reject legacy mutation contracts against multi-member series before
writing, while ordinary one-member sankalpas retain the existing compatibility path. Supported
linked commands identify their contract version as well as their expected service instance.
Use `Linked-Sankalpa-Version: 1` for extension, session, and lifecycle mutations on linked series
and linked contribution reads. A legacy collection read returns an upgrade-required refusal
when it contains multi-member vows, preserving the old array contract rather than adding
placeholder row shapes or returning owner-only totals as linked progress. Detail, session, and outcome
reads for those vows require the linked contract; ordinary one-member reads remain compatible.
Missing or unsupported versions yield a distinct upgrade-required refusal, not a session business
rejection. The client keeps unresolved commands pending until the compatible contract is available.
Updated clients can add the header to an existing pending operation after verifying the same
service's capability; its ID, owner, performed time, and service binding never change. Already
accepted/deleted same-owner identities can be replayed under the identity-v1 contract without
new mutations. New linked writes require the linked version. This handles a pending log whose
owner becomes linked while its request is in flight, without dropping or duplicating the action.

## Client state and celebration

The authoritative snapshot contains vow links, provenance, and unique session facts. Preserve
the existing overlay order: merge pending creates by ID, subtract pending deletes by ID, then
derive contributions to every cached series member. Suppression is global by session ID, not by
the currently displayed vow. A rejected operation corrects all views and produces the existing
single durable notice. Server acceptance reaches the base cache before operation removal.

Scope processing gates and the one-minute recent-log guard to `(serviceInstanceId, seriesId)`.
Their entries still carry individual session identities for Undo and expiry. Migrate retained
guards using cached membership; after extending a previously unrelated vow, its root ID remains
the guard key. Membership and cached timelines must be available before linked offline logging
is offered. An incomplete cache blocks starting that logging action; it does not block delivery
of an already journaled operation with a known owner and identity. Refresh instead of guessing
which vows count locally.
Server decisions reconcile stale cached lifecycle state through the existing rejection mechanism.
Stage refresh data before publishing it. Every fact must resolve to its cached owner and series,
and pagination must be complete for the requested contribution range. Missing members or an
incomplete refresh retain the previous valid snapshot and unresolved overlays. Server reads use
consistent transaction snapshots. A practice revision in existing service metadata detects
changes across paginated requests; clients restart staged refreshes rather than mix revisions.
The client refresh publication checks still prevent older
same-service or different-binding data from replacing accepted state.

Extension creation has no speculative local vow. Persist the source, stable extension ID,
requested count, and service binding before its request; an uncertain result is resolved by
retrying that exact request. Keep the attempt until the authoritative result is cached. Do not
accept offline extension creation or invent a second extension while the attempt is unresolved.
Apply the same service-binding and late-response publication checks as session operations.
The extension result refreshes series membership and all affected contribution views.
This is a small extension-attempt record separate from the session journal. Cancellation before
submission clears it without a command; after submission, uncertainty must be resolved rather
than reported as cancellation. An existing-child conflict resolves to the authoritative child
and informs the user. A definitive parameter refusal clears the attempt without adding a vow.

Successful completion uses the existing `CompleteSankalpa` result to acknowledge that vow and
duration. Permanent achievements are derived from separate vows in Completed - Successfully,
with completion time taken from their own terminal transition. There is no achievement aggregate,
points system, or event bus. Refresh and session correction do not manufacture another completion
action. An extension copies only nonterminal history, so it does not inherit a completed achievement.

## Persistence and migration

Add `series_id`, nullable `extension_of`, and transition `origin_sankalpa_id`. Enforce a unique
non-null `extension_of`, valid references, and verify same-series parents, increasing durations,
equal practice fields, valid inherited history, and a single root when loading/restoring data.
Root timelines contain only their own origins. All series nodes must be reachable from their
root; parents must precede children in creation order. Validate ledger owners against existing
vows as well as active/deleted session consistency. Run cross-record validation at a consistent
snapshot; per-vow decoding alone cannot establish these invariants.
Index series membership and owner/date session reads. Do not persist contribution rows or counts.

Backfill existing vows as their own series roots and existing transitions with their owning vow
as origin. Leave session IDs, owners, ledger states, log times, and service identity untouched.
Apply the same logical migration to local-file schemas and backups; reject unsupported versions
and malformed links rather than partially importing them. A backup restores the linked collection
as a whole, preserving source references and provenance. Existing reliability recovery remains
fail-closed. The session-reliability design's owner-based ledger remains authoritative; the series
capability and read/overlay rules here extend its earlier per-sankalpa assumptions.

## Requirement coverage and verification

| Requirement group | Architectural responsibility |
|---|---|
| Explicit, progressively longer series | Immutable root/source fields, extension factory, unique child constraint |
| Confirm duration and preserve source | Preview from source commitment; atomic creation of a separate vow |
| Old start date and inherited pauses | Extension-specific factory; copied timeline with origin provenance |
| Existing and future sessions shared in both directions | Active series candidates plus performed-time contribution predicate |
| Logging destination eligible | Original `logSession` validation on the requested owner |
| Own histories/counts, unique journal totals | Shared contribution helper and union by session ID |
| Repeat confirmation across series | Series-scoped client gate and recent-log guard |
| Undo/deletion and unresolved operations consistent | Owner-routed command, global ID suppression, derived views |
| Separate lifecycle and wins | Independent timelines, completion acknowledgement, derived achievement list |
| Narrow initial scope | Immutable links/practice fields; no branching, unlinking, scoring, or event infrastructure |

The behavioral and race checks are specified in [Testing strategy](08-testing-strategy.md).
Architecture review results are recorded in [Linked extension review](12-linked-extension-review.md).

## Detailed design

[Linked extension detailed design](../../design/linked-sankalpa-extensions/README.md) specifies
command algorithms, revision-bearing read contracts, transaction retry boundaries, migrations,
client state machines, acceptance coverage, and the design review/fix record.
