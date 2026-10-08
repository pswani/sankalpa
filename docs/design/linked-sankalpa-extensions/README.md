# Linked Sankalpa Extensions — Detailed Design

Status: reviewed October 7, 2026. Backend and connected iOS app implemented and verified; independent local-file support remains pending.
See [Backend implementation review](backend-implementation-review.md) and [Connected iOS implementation review](ios-implementation-review.md) for the implementation → test → fix → review → fix results.

The user extends an ongoing vow into a longer, separately completable vow. Sessions remain
single recorded facts and count toward eligible members of their explicit linked series.
Completing the shorter vow preserves its win while the longer vow continues.

The sources of truth are the [feature requirements](../../requirements/linked-sankalpa-extensions.md),
[base requirements](../../requirements/sankalpa.md), and
[accepted architecture](../../architecture/ddd/11-linked-extensions.md). The existing
[session reliability design](../session-reliability/README.md) remains in force for identity,
Undo, deletion, pending operations, service binding, and recovery. This design supplies concrete
changes to its earlier per-vow assumptions.

## Design map

| Document | Implementation questions |
|---|---|
| [Domain and commands](domain-and-commands.md) | Fields, factories, contribution rules, command algorithms, transaction ordering |
| [Persistence and migration](persistence-and-migration.md) | Schema changes, history validation, consistent reads, file/cache migration |
| [Contracts](contracts.md) | Requests, response fields, errors, version negotiation, paging |
| [Clients and journeys](clients-and-journeys.md) | Extension attempts, refresh, overlays, repeat confirmation, completion, UI behavior |
| [Testing and delivery](testing-and-delivery.md) | Traceability, acceptance scenarios, races, implementation order, release gates |
| [Design review](design-review.md) | Design → review → fix findings and final assessment |
| [Backend implementation review](backend-implementation-review.md) | Backend changes, review fixes, and clean verification evidence |
| [Connected iOS implementation review](ios-implementation-review.md) | Connected client changes, recovery review, and native verification |

## Implementation boundaries

The backend is Java with JDBC and adapter-managed transactions. Extend `SankalpaService`,
`SankalpaUseCases`, their existing repository ports, the JDBC adapter, web DTOs, and transaction
wrapper. Keep framework dependencies outside the domain. Do not add a series aggregate or a
second command framework.

The original iOS app under `app/` uses the backend through `RemoteSankalpaService` and a durable
session journal/cache. Its Swift core must mirror the domain behavior, and its client must use
unique session-fact reads rather than concatenate each vow's contributed history.

The independent app under `app2/` uses `FileStore`. Apply the same domain and contribution rules
through its existing application service and atomic-file commit. It does not gain a backend,
network journal, or automatic import from `app/`. The two Swift cores currently live separately;
update them consistently without making package consolidation part of this feature.

## What changes

- Add immutable root/source links and transition provenance to vows.
- Add one extension factory and one extension command with stable creation identity.
- Replace owner-only progress reads with the shared contribution helper.
- Keep session ownership and the identity ledger unchanged; delete through the original owner.
- Scope client logging gates to the series and project pending changes across eligible vows.
- Acknowledge each vow's successful completion and derive a separate achievement for it.

No session-copy workflow, contribution table, event infrastructure, activity catalogue, link editing,
branching, scoring, or new conversational extension tool is included. Existing conversational
session logging must still respect linked-series contracts and explain shared effects.

## Consistency refinement

The architecture calls for consistent read snapshots. Multiple paginated HTTP requests cannot
share a database transaction. This design uses one practice revision in existing service metadata
to detect a changed collection and restart a staged refresh. It stores no historical snapshots
or projections. [Persistence and migration](persistence-and-migration.md) defines the counter;
[Contracts](contracts.md) defines revision-bearing pages.
