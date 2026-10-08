# Design Review

Reviewed October 7, 2026. This is a design → self-review → fix record for documentation, not
an implementation certification. Review inputs were the accepted requirements/architecture,
existing Java domain/service/JDBC/transaction/web code, remote Swift cache/journal/refresh,
local FileStore and application service, and the existing conversational proposal path.

## Pass 1 — Draft against requirements and current code

Produced the domain/command algorithms, persistence/migration design, transport contracts,
client journeys, and acceptance/delivery plan. Reviewed the differences between current
owner-only behavior and linked contribution behavior.

| Finding | Fix in the design |
|---|---|
| Remote refresh concatenates each vow's session history and rejects duplicate IDs. Linked histories would duplicate shared facts. | Refresh from canonical unique-fact pages; keep duplicate validation and derive per-vow views. |
| Request-level consistent transactions cannot guarantee consistency across multiple HTTP pages. | Add a revision counter in existing service metadata, return it with snapshot reads, bind cursors/refresh requests to it, and restart staged refresh on mismatch. No retained snapshot service. |
| Filtered candidate pages can appear empty while eligible older facts remain. | Scan chunks until an eligible page plus lookahead is filled; use last emitted eligible row for continuation. |
| Adding fields to bootstrap CREATE statements would leave existing tables unchanged. | Explicit versioned startup migration, backfill/constraints/validation, and fresh-store schema parity. |
| A legacy collection cannot decode invented upgrade-placeholder rows in its existing array. | Return upgrade-required for a linked legacy collection; preserve one-member fallback and versioned linked reads. Refine architecture chapter 11 accordingly. |

## Pass 2 — Identity, cache, and adjacent-path review

Walked through uncertain creation, concurrent linking, shared deletion, cache-write failure,
conversation confirmation, and local-file parity.

| Finding | Fix in the design |
|---|---|
| Version gating only before the write transaction can race extension creation. | Check multi-member membership under the root guard; propagate an explicit application contract argument. |
| A pending old-format log could become a permanent rejection after its owner is linked. | Upgrade-required keeps the operation/overlay; add a negotiated header without changing identity, values, or binding. Preserve nonmutating exact replay. |
| Revision queried after serialization could describe a newer state than the response body. | Return payload and metadata together from the same transaction. |
| Accepted extension creation could disappear after failed fact refresh, or regress newer cached metadata. | Return a complete same-snapshot series bundle, persist accepted attempt until cache merge, invalidate old publication, and reject stale metadata merges. |
| Existing-child conflict can resolve to another ID/duration; treating it like exact success would misreport creation. | Distinguish conflict resolution from exact creation, verify source link, show actual duration, and preserve mismatched-success quarantine. |
| A definitive extension refusal left as unresolved could be retried automatically after relaunch. | Persist resolvedNotice, stop automatic resend, and start a corrected action only after resolution. |
| Retrying a nested session command can leave conversation confirmation in a rollback-only outer transaction. | Preserve raw-service injection; retry the entire proposal confirmation transaction, with proposal-before-root ordering. |
| Existing conversation code catches domain errors and resolves rejected proposals. | Make upgrade-required an application contract exception so refusal does not resolve the proposal. |
| The local app lacks full permanent deletion/repeat behavior assumed by feature requirements. | Include local permanent shared deletion, stable logging-action IDs, conflict-aware save/replay, and durable recent guards in schema 2. No network journal or server ledger is added there. |

## Pass 3 — Final scenario, traceability, and scope review

Rechecked the revised algorithms and contracts against these sequences:

1. Extend 40 → 90 after 30 days; complete 40; continue 90; complete 90 with two distinct wins.
2. Diverge paused intervals and log through either eligible owner; backfill after terminal state.
3. Extend 90 → 180 after the root completes; copy immediate-source history with ancestor origins.
4. Retry after source completion, lost response, accepted-result cache failure, and existing child.
5. Delete through a non-owner view; Undo while delivery is unresolved; extend after deletion.
6. Page through paused candidates and identical-time facts; mutate between collection/history/pages.
7. Upgrade legacy schema/cache/journal; resume interrupted migration; restore diverged valid history.
8. Confirm existing conversational session proposals while linking/version support changes.

The [acceptance plan](testing-and-delivery.md) maps every feature requirement group to a design
responsibility and specifies 33 named domain, command, read, persistence, client, and compatibility
cases. The core architecture remains unchanged: independent vow aggregates, immutable explicit
membership, one fact per session, owner-based command identity, and derived progress/achievements.

Result: no unresolved design blockers found. Concrete SQL migration/transaction behavior and
Swift persistence/interaction changes still require the specified implementation tests; this
review does not claim those tests passed. General timezone policy remains the existing assumption.

## Documentation validation

Passed: 20 design/architecture documents, 52 local Markdown links, balanced fenced examples,
trailing whitespace checks, 33 unique acceptance-case IDs and their references, and
`git diff --check`. Reviewed version/status/error names across chapters for consistency.
Implementation gates remain separate from these documentation checks.
