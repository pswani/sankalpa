# Testing and Delivery

These checks are implementation acceptance criteria. No feature code or implementation tests
have been executed as part of writing the design. Documentation verification and review results
are recorded in [Design review](design-review.md).

## Requirements traceability

| Requirement group | Design responsibility | Acceptance coverage |
|---|---|---|
| Explicit linear series and navigation | Immutable root/source fields; unique direct child; ordered series read | D1, C1, P1 |
| Greater whole-period duration and unchanged source | Factory and locked extension command | D1–D3, C1–C3 |
| Original old start and inherited pauses | Dedicated factory; timeline value copy/provenance | D2, D4, P2 |
| Existing/future sessions share in both directions | Contribution helper, range-bounded series candidates | D5–D7, R1–R3 |
| Logging owner itself eligible | Existing owner validation before creating one fact | D6, C4 |
| Counts once per vow and once overall | Identity sets, canonical fact reads, filtered pagination | D5, R2–R4, U1 |
| Series-scoped repeat confirmation | Client gate/recent guards and migration | U2, U3 |
| Undo/deletion/pending effects across vows | Immutable owner route, global suppression, unchanged ledger | C4, U1, U4, P3 |
| Independent lifecycle, completion, and wins | Separate timeline suffixes; acknowledgement from action; derived achievements | D4, D7, U5 |
| Finite source/state restrictions and narrow scope | Factory refuses unsupported sources; manual extension only | D3, C3, A1 |

## Domain cases

| ID | Case and required assertion |
|---|---|
| D1 | With clock on July 30, extend a July 1, 40-day In progress vow to 90 days. Source still ends August 9; child ends September 28. Practice fields/start copied; total count 90, not 130. |
| D2 | Extend a valid older-than-one-year source; inherited start accepted. An unrelated declaration with that start is still refused. Month/year extensions retain January 31/February 29 boundary behavior and existing count limits. |
| D3 | Reject indefinite, Not started, Completed, Stopped, equal/shorter count, out-of-range count, and an already-past derived new end. Accept an end date of today. |
| D4 | Copy Begin/Pause/Resume with original timestamps/origins; Paused source yields Paused child. Later source and child transitions diverge independently. Extending again retains ancestor origins. No second Begin. |
| D5 | Existing, late-backfilled, and newly logged facts contribute once to each eligible member. Distinct same-time IDs remain distinct. Matching unrelated titles/activities never establish sharing. |
| D6 | Logging through an ineligible owner is refused even if a peer accepts that time. A shared fact is excluded from a peer's own paused interval or uncovered dates. |
| D7 | Terminal members receive only eligible historical contributions. Closed outcomes and partial terminal cutoffs remain unchanged. Deletion changes tallies but never completion state or achievement. |

Run the applicable domain/query cases in Java and both Swift cores using the same scenario fixtures
and their existing clock/calendar abstractions. No live model/provider calls are required.

## Commands and real concurrency

| ID | Case and required assertion |
|---|---|
| C1 | Two IDs concurrently extend one source: exactly one child/history; loser identifies it. Exact retries return created=false after source completes. Changed input under same ID conflicts. |
| C2 | Extension versus Pause/Resume/Complete reads one committed source timeline. Capture `now` after guard. Child copying and membership are atomic; injected write failure leaves none. |
| C3 | Source becomes terminal before first extension commit: refuse; source becomes terminal after commit and response is lost: replay child. Same extension ID attempted under unrelated roots cannot win twice. |
| C4 | Shared deletion routed from non-owner history removes one fact and all contributions. Direct wrong-owner commands conflict. Delete-before-create, log/deletion races, same-time distinct identities, and uncertain Undo preserve the existing ledger rules. |
| C5 | Linked-version gate races extension creation: old-format new mutation cannot commit after linking unchecked. Exact accepted/deleted identity replay remains nonmutating. Upgrade-required leaves the queued operation/proposal unresolved. |
| C6 | Manual and conversation paths follow documented lock order, revision increments commit atomically, and bounded contention exhaustion is retryable. No reversed proposal/root lock acquisition; confirmation retry restarts its entire outer transaction. |

Use at least two connections and explicit barriers, not sleeps or pool serialization, for overlapping
SQLite and test-database transactions. Assert the final ledger/facts/history/revision as well as
the returned status. Use injectable failures immediately before child/history/revision commit.

## Reads and protocol

| ID | Case and required assertion |
|---|---|
| R1 | Session rows expose identical owner aliases and exactly eligible contributor IDs. All progress/count/outcome surfaces use the same helper. |
| R2 | A series has many ineligible paused candidates before an eligible row. Fill filtered pages without truncation; cursor resumes after the last emitted fact; ordering survives identical performed times. |
| R3 | Requested week/month range expands to actual period boundaries before filtering. Lifetime count and absent-range canonical refresh include older facts beyond displayed pages. |
| R4 | Canonical journal reads contain one row per fact; combined totals are a union, not sums. Duplicate conflicting rows, alias mismatch, or missing owners fail validation. |
| R5 | Mutate the practice between list/history/pages: required revision/cursor refuses the changed snapshot, refresh restarts, and no mixed cache publishes. A continuously changing store exhausts two passes and retains the previous valid view. |
| R6 | Feature header, expected instance, revision, cursor scope/range/version/size validation, status codes, replay flags, conflict child ID, and Location are covered by controller/OpenAPI fixtures and Swift decoding tests. |

Retain old numbered pagination tests for compatible one-member clients. New cursor fixtures must
not be decoded using the old `totalPages` contract. Revision is a decimal string, tested beyond
JavaScript's exactly representable integer range so external tooling cannot truncate it.

## Persistence and recovery

| ID | Case and required assertion |
|---|---|
| P1 | Empty and populated SQLite/test stores migrate; restarting is idempotent. Roots/origins assigned, constraints enabled, identities/timestamps/service binding unchanged. Crash/failure cannot produce a served partial schema. |
| P2 | Restore rejects branches, cycles, missing/foreign roots/parents/origins, changed practice fields, invalid duration growth, and malformed inherited prefix/suffix. Accept diverged current source history, equal-time sequence boundaries, expired children, and now-terminal sources. |
| P3 | ACTIVE/DELETED integrity and session-owner eligibility survive migration/restore. A deleted fact cannot appear in an extension created later or after delayed delivery. |
| P4 | FileStore v1 → v2 and backups preserve original bytes on failure and publish only after atomic write; recent-log guards and permanent shared deletion work after relaunch. Unknown future versions fail closed. Contribution recount replaces owner-only counts. |
| P5 | Remote cache/journal migration preserves all operation IDs, owners, revisions, notices, and service instance. Interrupted multi-file migration can resume; an unbound legacy outbox is not silently upgraded. |

Run local-file save/export/restore failures against isolated temporary stores. Do not use production
practice files or databases as test fixtures.

## Client and interaction cases

| ID | Case and required assertion |
|---|---|
| U1 | Pending creates/deletes project across every eligible cached member; journal has one identity. Accept/reject/cache failure and relaunch preserve Undo and global suppression. |
| U2 | Switching members cannot bypass a processing gate; 60-second repeat is series-scoped, confirmation creates a fresh ID, and unrelated roots remain independent. |
| U3 | Guard migration/extension retains stable root scope. Missing membership blocks starting new linked logs without discarding pending delivery. |
| U4 | Extension attempt is durable before send; lost response/relaunch/cache failure retries the same ID. Late response checks binding/revision; service relocation is blocked while unresolved. Existing-child conflict resolves without inventing another request or claiming the requested duration was created; mismatched success IDs remain protocol failures. |
| U5 | Complete 40-day vow, continue and complete 90-day vow: two wins, independent states, unique journal. Refresh/session correction does not replay the completion acknowledgement. |
| U6 | Original and extension titles may be identical; duration/end date distinguish navigation and deletion confirmation. Total-duration preview and cancellation are accessible and leave source unchanged. |

At least one native journey per app proves extension, shared logging, independent completion, and
owner-routed deletion. Include accessibility text sizes, dark mode, and restart
for the new form/linked-history/acknowledgement surfaces. Do not add celebration artwork tests.

## Compatibility and adjacent features

| ID | Case and required assertion |
|---|---|
| A1 | Old server disables Extend; one-member fallback works. Old client against a linked collection receives upgrade-required and cannot change linked state. Updated client adds transport header without changing queued command identity. |
| A2 | Existing conversation session proposal displays owner/shared effects; confirmation gates linked version under transaction. Upgrade refusal leaves it pending. Existing executed-confirmation replay remains safe. No extension tool or new proposal kind appears. |
| A3 | Local app remains file-backed and separate from the remote app. No automatic migration/import across the two stores. |

## Implementation order and release gates

1. Domain fields, factories, eligibility helper, and collection validation with domain fixtures.
2. Schema/file/cache migrations and root write ordering with failure and real concurrency coverage.
3. Extension command/replay, revision metadata, contribution queries, and versioned contracts.
4. Remote client DTOs, canonical refresh, durable attempt, overlays, series guards, and error classification.
5. Local-file commands/queries and atomic extension creation; keep both Swift domain copies aligned.
6. Manual forms, linked navigation/history, deletion explanation, separate completion acknowledgements;
   adapt existing conversational session confirmation without adding extension interpretation.
7. Run Java/Swift/storage/HTTP regressions and the native acceptance journeys against clean and
   migrated stores. Enable the capability only when all server linked contracts work together.

Do not expose extension UI or advertise server support halfway through those dependencies. Release
requires all IDs above covered by passing assertions, existing session reliability regressions
passing, round-trip backup/recovery verified, and no unresolved protocol/identity/data-loss failures.
Roll back code only with a compatible data-reader/writer; after linking live data, restoring a
pre-feature backup is the explicit data rollback, not a silent flattening of the series.
