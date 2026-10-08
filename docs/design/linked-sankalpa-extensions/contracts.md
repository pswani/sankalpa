# Contracts

Paths below include the existing `/api/v1` prefix. Keep JSON dates/times and lifecycle enum
spellings consistent with the current API. Times use the configured application timezone.
The new contract is additive for unrelated vows; linked semantics are explicitly negotiated.

## Capability and request context

Add `linkedSankalpaExtensions: 1` to the existing capabilities response, retaining
`sessionCommandIdentity`, `serviceInstanceId`, and `assistant`. Missing linked capability means
unsupported, not a server with no linked vows.

Updated clients send:

```http
Linked-Sankalpa-Version: 1
Sankalpa-Service-Instance: <verified persistent service instance UUID>
```

Extension creation always requires both. New session/deletion and lifecycle mutations require
them when the requested vow belongs to a multi-member series. Supported linked reads also send
them. Instance mismatch is checked before domain lookup or mutation. Membership-dependent
version checks run under the command's root guard, not only before transaction entry.

Feature reads return `Sankalpa-Service-Instance` and `Sankalpa-Practice-Revision` response headers.
Revision is a nonnegative decimal integer string scoped to that service instance, not a domain
timestamp or a new entity ID. Requests participating in a refresh send
`Sankalpa-Practice-Revision: <first read revision>` after obtaining the first response; a differing
read snapshot refuses with `READ_SNAPSHOT_CHANGED`. Cursor revision and supplied revision must agree.

## Extension creation

```http
POST /api/v1/sankalpas/11111111-1111-4111-8111-111111111111/extensions
Idempotency-Key: 22222222-2222-4222-8222-222222222222
Linked-Sankalpa-Version: 1
Sankalpa-Service-Instance: <verified UUID>
Content-Type: application/json

{
  "id": "22222222-2222-4222-8222-222222222222",
  "totalPeriodCount": 90
}
```

`id` is required and must match `Idempotency-Key`. `totalPeriodCount` is an integer in the existing
1–3,650 range, measured from the original start. The client cannot send title, activity, frequency,
start date, source lifecycle, series ID, or creation time to override inheritance.

Response envelope:

```text
ExtensionResponse
  created: boolean
  sankalpa: SankalpaResponse
  series: array of VowSnapshot { sankalpa, lifecycleHistory }
```

The series bundle contains every member and its current timeline from the same transaction/read
snapshot as the result. It supplies sufficient membership/provenance to durably cache accepted
creation even if the later fact refresh fails. It is not a complete replacement for session facts.
First acceptance returns `201` with `Location: /api/v1/sankalpas/{extensionId}`. Exact replay returns
`200`, `created: false`, and the same child identity/commitment/creation time with current state.
Both responses carry the service/revision headers. No lifecycle or session command is executed
as a side effect of returning this bundle.

## Vow and lifecycle rows

Add these fields to the existing `SankalpaResponse`:

| Field | Meaning |
|---|---|
| `seriesId` | Original/root vow ID, including self for unrelated vows. |
| `extensionOf` | Immediate source ID or null. |
| `directExtensionId` | Immediate child ID or null, derived from current membership. |
| `totalSessionCount` | Unique eligible contributions to this vow, not owner-only count. |

Keep `periodCount` as the vow's total duration, not extra periods. Keep `declaredAt` as this vow's
own creation time. Creation and lifecycle responses use the same enrichment rules as detail reads.
`totalSessionCount` is assembled from the shared helper at the response revision; it is a read
value, not stored domain state. Local overlays recalculate it from visible facts.

Add `originSankalpaId` and `sequenceNumber` to lifecycle rows. Sequence numbers start at zero
within the receiving vow's timeline. `inherited` is derived by comparing origin with the receiving
vow; clients must not assume all transitions before creation are actions on that receiving vow.
Existing effective/recorded timestamps remain unchanged.

`GET /api/v1/sankalpas/{id}/linked-series` returns an ordered array of `VowSnapshot`s from root
to longest extension, even when ancestors are completed. It includes each member's own progress
and terminal state; successful members form the persistent achievement list. Navigation uses IDs,
not titles. The collection endpoint retains its array envelope for supported clients.

## Session fact rows and commands

The row retains `id`, `sankalpaId`, `occurredAt`, and `loggedAt`, and adds:

```text
loggingSankalpaId: UUID              // equals sankalpaId, compatibility alias
contributingSankalpaIds: array<UUID> // ordered from root to longest eligible member
```

The alias must match; conflicting values are a protocol failure. Contributor IDs are authoritative
read annotations at the response revision, not stored assignments or identity owners. Pending
local operations derive annotations from cached membership and timelines.

Log uses the existing `POST /api/v1/sankalpas/{loggingOwnerId}/sessions`, stable body/header session
ID, and performed time. First creation remains `201`, exact replay `200`, with an immutable
single fact. Delete uses `DELETE /api/v1/sankalpas/{loggingOwnerId}/sessions/{sessionId}` and
remains `204`. A row displayed in another vow routes deletion to `loggingSankalpaId`.
Undo always uses its original receipt. Neither command replaces the owner with another contributor.

Log replay may return updated contributor annotations while retaining the accepted fact unchanged.
Receipts and success messages identify the owner and affected vows separately. A `204` deletion
can carry service/revision headers without a body. Preserve the existing minimal ledger and
delete-before-create behavior; do not retain deleted contributor IDs in the ledger.

## Cursor reads

| Endpoint | Scope |
|---|---|
| `GET /api/v1/sessions` | Unique active facts across the collection; canonical remote-cache refresh source. |
| `GET /api/v1/sankalpas/{id}/sessions` with linked header | Eligible contributing facts for the target vow. |
| Existing period outcomes/detail/list/history | Same domain rules with series-aware counts and revision-bearing responses. |

Both cursor endpoints accept `size` (1–200, default 100), optional `cursor`, and optional inclusive
`from`/`until`. Supply both range dates or neither; absent dates mean the full history, required
for lifetime cache refresh. Invalid/reversed dates are refused. Order is performed time descending,
then canonical session UUID descending. New cursor responses use:

```json
{
  "content": [],
  "nextCursor": null,
  "hasMore": false
}
```

The cursor encodes a format version, service instance, practice revision, endpoint/target scope,
range, ordering, and last emitted `(occurredAt, id)`. It is opaque to clients; decoding validates
field types, length, version, and request compatibility. It is a read navigation token, not an
authorization credential. Reject malformed or wrong-scope cursors. A changed practice revision
returns `READ_SNAPSHOT_CHANGED`; never mix pages from different revisions.

For contributed history, scan candidates in fixed chunks, apply eligibility, and collect `size + 1`
eligible rows. Return the first `size`, using the last emitted eligible row as the continuation
boundary; the extra row proves `hasMore`. Ineligible candidates must not consume the page size.
If no eligible row remains, return empty/end. This can scan many candidates but never silently
caps history. Combined journal facts already have one row per ID and need no contribution fan-out.

Do not reuse the old `page/totalPages` response shape for the linked cursor contract. Single-member
requests without the linked header retain the existing numbered-page response. Clients must
choose a decoder from the negotiated contract, not guess from whether the response is empty.

## Failure contract

Use the existing RFC 9457 problem envelope, including its stable `code`. New refusal codes:

| Status | Code | Client action |
|---|---|---|
| 400 | `INVALID_EXTENSION_REQUEST` | Correct malformed/missing ID, header mismatch, integer/range syntax. |
| 422 | `SOURCE_NOT_EXTENDABLE` | Explain state/indefinite source; no child added. |
| 422 | `DURATION_NOT_GREATER` | Keep preview open and choose a greater total count. |
| 422 | `EXTENSION_ENDS_IN_PAST` | Keep preview open and choose a current/future end date. |
| 409 | `EXTENSION_ALREADY_EXISTS` | Resolve authoritative child from `errors.extensionId`; do not create another. |
| 409 | `EXTENSION_IDENTITY_CONFLICT` | Preserve evidence, block that attempt, and inform the user. Do not silently change its ID. |
| 409 | `LINKED_SANKALPA_UPGRADE_REQUIRED` | Keep unresolved operations/proposals; negotiate/upgrade rather than undoing their overlays. |
| 409 | `READ_SNAPSHOT_CHANGED` | Discard staged pages and restart the read; no mutation attempted. |
| 400 | `INVALID_SESSION_CURSOR` | Discard the cursor and restart a valid query. |
| 503 | `PRACTICE_WRITE_CONTENDED` | Keep the stable operation/extension identity and retry later. |

Existing not-found, identity-conflict, permanently-deleted, service-instance-mismatch, and session
business codes retain their meaning. Unknown codes, malformed success, timeouts, and 5xx responses
are indeterminate for submitted mutations; keep the durable attempt/operation. A malformed read
retains the prior cache. Classify by stable code, not just status: an upgrade-required `409` is
different from an identity-conflict `409`.

## Compatibility and conversation

Legacy clients can continue operating on unrelated one-member series. Nonmutating session
identity-v1 replay remains available even if that owner later becomes linked. A legacy collection
read when linked vows exist returns upgrade-required for the collection, rather than changing
its array to invented placeholder rows that an old client cannot decode. Legacy linked detail/
session/outcome reads and new linked writes likewise require upgrade. No server response silently
returns owner-only progress for a linked vow.

The existing AG-UI run/confirmation path carries the linked version and expected instance when
reading or proposing/confirming linked sessions. Session proposal confirmation identifies the
owner and affected vows before commit. Contract refusal must leave an unresolved proposal pending;
it cannot become a caught domain refusal that permanently rejects the proposal. The native card
uses its retained owner/performed time and a current validated series view to preview contributor
IDs with the domain predicate, plus the explanation that all eligible linked vows share the session.
This preview is not a stored assignment; acceptance reads show the authoritative contributors.
Manual and assistant confirmation paths use the same client series gate and recent-log guard.
Existing already
executed confirmation replay may return its outcome without another mutation. No conversational
extension tool, new proposal kind, or automatic model-controlled sharing choice is added.
