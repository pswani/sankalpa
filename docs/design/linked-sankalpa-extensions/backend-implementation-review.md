# Backend implementation review

Status: backend complete, reviewed and verified October 7, 2026. Native client and local-file
implementation remain pending. This record covers the Java backend portion of the approved design.

## Implemented behavior

- Create a longer, separately completable vow through the dedicated extension factory and command.
  Immutable series/source IDs form a linear series; lifecycle history is copied by value with origin
  IDs. Original commitment and later lifecycle actions remain independent.
- Record each session once with its immutable owner. Counts, outcomes, contributed histories, and
  contributor annotations use the same eligibility predicate. The canonical journal returns unique
  facts. Deletion retains the existing permanent identity ledger and removes every contribution.
- Serialize extension, lifecycle, and session commands through the root write guard. Claim extension
  identities with insert-only writes and enforce one direct child in the database. Exact retries
  retain their accepted identity; transaction collisions restart the complete command up to three
  attempts, including the outer conversation-confirmation transaction.
- Negotiate linked contract version 1 and service identity explicitly. Legacy linked reads/new
  mutations refuse with upgrade-required; accepted session identity and executed confirmation replay
  remain nonmutating. Conversation contract refusal leaves the proposal pending. No extension tool
  or new proposal kind was added.
- Publish extension and linked-series endpoints, enriched vow/lifecycle/session DTOs, unique journal
  and contributed cursor pages, and revision-bearing responses. Cursor continuation validates scope,
  range, service, and revision, and filters candidates before consuming page capacity.
- Upgrade SQLite before serving requests, preserving identities and service binding. Validate the
  complete collection, lifecycle sequences, and ledger before committing the migration marker.
  Populated file upgrades create a consistent backup; unsupported and partial schemas fail startup.

## Implement → test → fix → review → fix

| Review finding | Resolution and evidence |
|---|---|
| Generic session response hid the existing page schema from OpenAPI. | Publish both response alternatives and explicit linked headers; existing and new contract tests pass. |
| A create could enter the repository's update path if another root claimed its ID. | Add insert-only creation; concurrent unrelated roots sharing an extension ID produce one child and an identity conflict, with a valid stored collection. |
| SQLite deferred snapshots can collide immediately rather than wait for the winning writer. | Retry the entire transaction with bounded backoff; barriers inside initial reads prove overlapping connections yield one child, one authoritative conflict, and one revision increment. |
| Extension/lifecycle overlap must copy a committed source timeline. | Root guard precedes command time/history use; overlapping SQLite Pause/Extend test validates the resulting prefix and both committed revision increments. |
| Validation after migration commit could publish invalid upgraded records. | Validate domain records and ledger before commit; malformed timestamps and semantically ineligible owner facts restore the original SQLite schema/data without a marker. |
| Counts and page annotations repeated series/history reads for each row. | Calculate requested counts in one chunked fact pass per series and annotate a page from one loaded collection. Membership queries load only the requested series. |
| Backward command clocks could rewrite previously established eligibility. | Reject lifecycle/extension audit time regression; retain Begin's permitted effective backdate. Correct the existing concurrency fixture to use a Pause recorded after Begin. |
| JSON numeric coercion could truncate a fractional period count. | Disable float-to-integer coercion; extension requests reject fractional counts and attempts to override inherited fields with the documented request error. |
| Large revisions could lose precision in external tooling. | Keep revision headers/cursor fields as decimal strings; controller test covers 9007199254740993. |

The review also checked source-state restrictions, old-start inheritance, calendar anchoring,
independent completion, shared deletion, source completion before replay, ledger replay precedence,
root/proposal lock ordering, cursor lookahead and continuation, and version gates inside writes.
No unresolved backend correctness finding remains from this review.

## Verification

`backend/scripts/verify.sh` completed a clean `mvn clean verify` build and executable JAR packaging:
**97 tests, 0 failures, 0 errors, 0 skipped**. This includes the existing 69 regression tests and
28 added feature tests. `git diff --check` passes.

Coverage includes Java domain/application and architecture checks, H2/HTTP/OpenAPI integration,
real SQLite migration/restart/backup reads, storage and revision failure rollback, overlapping
SQLite and H2 commands, unique fact pagination, revision invalidation, compatibility, and pending
conversation-confirmation recovery. Tests use isolated databases and deterministic clocks; no live
model provider or production practice database is involved.

The latest raw output and compact verdict are generated under `backend/logs/`; the compact verdict
is `backend/logs/latest-summary.md`.

## Operational boundaries

The original SQL bootstrap remains idempotent; a versioned startup adapter performs the upgrade for
fresh and existing databases. Production SQLite schema/data changes are rollback-atomic. H2 DDL
is not transactional; its failed partial upgrade is detected and prevents startup. Migration backup
location and explicit recovery behavior are documented in `backend/README.md`.

This implements the server contract and advertises capability 1. The native extension forms,
shared cache/outbox projections, series-scoped client guards, and `app2` file migration described
in the full design are not part of this backend request. The complete product release still needs
those client acceptance journeys.
