# Persistence and Migration

## Relational changes

The current backend has `schema.sql`, JDBC repositories, a session identity verifier, and service
metadata. Merely adding columns to `CREATE TABLE IF NOT EXISTS` does not migrate existing stores.
Add an explicit startup migration with a persistent version marker before the updated repositories
or feature endpoints serve requests. Preserve a restorable copy before changing the live file.

| Table | Change |
|---|---|
| `sankalpa` | Add required `series_id`, nullable `extension_of`; retain current domain `version`. |
| `sankalpa_lifecycle_transition` | Add required `origin_sankalpa_id`; retain sequence numbers/timestamps. |
| `service_metadata` | Add migration marker `linked_extensions_schema = 1` and `practice_revision = 0`. |
| `practice_session`, `session_identity` | No identity/owner/state changes. |

Final constraints include references from `series_id`, `extension_of`, and transition origins to
existing vows, a unique non-null direct source, and no self-extension. Use an explicit partial
unique index for SQLite, or equivalent nullable uniqueness on the test database. References use
RESTRICT; this feature does not add sankalpa deletion. Do not store end dates or contribution counts.

Indexes: `sankalpa(series_id, id)`, unique direct source, and active facts on
`(sankalpa_id, occurred_at, id)`. Series candidates join the fact's owner to the target series:

```sql
SELECT p.*
FROM practice_session p
JOIN sankalpa owner ON owner.id = p.sankalpa_id
WHERE owner.series_id = :root
  AND p.occurred_at >= :fromStart
  AND p.occurred_at < :dayAfterUntil
ORDER BY p.occurred_at DESC, p.id DESC
```

The query selects candidates, not contributions. The application filters with domain eligibility.
Use the existing timestamp semantics and configured application timezone. Confirm stored strings
have a consistent chronological ordering before using them as keyset boundaries; canonicalize
equivalent legacy timestamp representations if needed without changing their interpreted value.
Canonical UUID text supplies a deterministic tie break. Do not add timestamp-based uniqueness.

## Startup migration

1. Stop writes; inspect the persistent migration marker and schema. Use one migration owner.
2. Reject unknown future versions or contradictory partially migrated data; preserve original bytes.
3. In a migration transaction, add/backfill new fields. Every existing vow is its own root, every
   existing transition originates on its owning vow, and all source links are absent.
4. Apply final constraints/indexes. SQLite may require table rebuilding for required columns and
   references: preserve IDs, all column values, sequences, and child references; do not use
   destructive cascade deletion. Rebuild in dependency order and run foreign-key checks.
5. Verify the entire collection and the existing ACTIVE/DELETED ledger before committing the
   marker. Initialize the practice revision without replacing `serviceInstanceId`.
6. Commit, then serve versioned commands/reads. A crash rolls back to the old schema or leaves
   an explicitly recognized versioned migration state, never a guessed empty collection.

Fresh stores receive the final schema directly with matching markers. Repeated startup verifies
but does not backfill origins on already linked history. Running an older server against the
upgraded schema is unsupported once extensions exist; downgrade means restoring the preserved
pre-upgrade store, not stripping links from active data.

## Collection validation

Validate after decoding/reconstituting a consistent collection, before restore confirmation and
before accepting a migrated snapshot. Validate row-local values first, then cross-record rules:

- IDs are unique; every source, root, transition origin, session owner, and ledger owner exists.
- An original has no source and `seriesId == id`; its transitions originate on itself.
- Every extension reaches its declared root through existing same-series sources with no cycle.
- Each source has at most one child. All nodes in a series are reachable from its single root.
- Source/child activity, title, description, start, period, and frequency match. Both durations
  are finite and increase strictly. Child creation time is not before the source's creation.
- Inherited entries form the source's exact initial prefix, including origin, states, effective
  time, and recorded time. Ancestor origins cannot appear after the child's own entries begin.
- The inherited prefix is nonempty and ends in In progress or Paused at creation. Its entries
  cannot be recorded after child creation; it includes every source entry recorded strictly
  before creation. Equal timestamps use stored entry sequence and the persisted inherited prefix.
- Own child entries originate on that child and occur no earlier than creation. Later source
  entries need not appear on the child; do not require whole-timeline equality after divergence.
- Timelines follow the existing state/timing rules and agree with current state. Do not apply the
  unrelated-declaration one-year limit to inherited starts or restored history.
- ACTIVE identities have exactly one same-owner fact; DELETED identities have none. Active facts
  remain eligible on their logging owner at their performed time. There are no orphan facts.

Do not validate a historical extension against its source's current state or against today's
end-date condition; those were creation-time rules. A now-completed source or expired child is
valid data. Timestamp equality alone cannot prove which source transition preceded creation;
the saved prefix preserves that ordering without a new global audit sequence.

## Read consistency and practice revision

Every mutation affecting the practice increments a decimal 64-bit practice revision in the
existing metadata row within its write transaction, after other locks. Counter overflow is a
storage failure, never wraparound. Replay does not increment it. Conversation-confirmed changes
participate in the same transaction; proposal-only changes do not alter practice revision.

Every feature read captures revision, membership/timelines, and facts in one read transaction.
SQLite's read snapshot supplies this consistency; the test adapter uses equivalent repeatable
reads. The response carries `Sankalpa-Practice-Revision`. A continuation cursor names that revision;
if the current read snapshot has changed, return `READ_SNAPSHOT_CHANGED` so the client restarts.
There are no retained server snapshots, server cursor sessions, or cache projections.

Return payload and read metadata together from the transaction as a typed result. Controllers
must not query revision/service metadata again after the read transaction ends and attach that
newer value to an older payload. Command results similarly carry the revision of their committed
change and any same-snapshot bundle. Metadata fields are transport/application values, not part
of the `Sankalpa` aggregate.


The client collects all pages into a staging buffer. Every list, lifecycle, unique-fact, and linked
series response must carry the same revision and service instance. Different revisions discard
the staging buffer and restart. Limit an automatic refresh to two fresh attempts; continued
changes retain the previous valid cache and offer retry. A new snapshot is published only after
its last complete page, collection validation, durable cache write, and existing publication/binding
checks. A later mutation can make that snapshot stale, but cannot make it internally inconsistent.

Per-vow progress uses series candidates filtered before pagination. Summary/lifetime count
queries traverse all required facts in that read snapshot, chunking scans without changing the
snapshot. A list may load the unique fact set once and group it by series before counting; avoid
one full scan per vow. This is sufficient for the current single-user scale.

## Local file and remote cache versions

| Store | Existing version | Feature version | Migration |
|---|---|---|---|
| `app2` FileStore/backup | 1 | 2 | Assign root/origin fields; validate; atomic write before publishing migrated state. |
| `app` CachedPractice | 2 | 3 | Assign root/origin fields to valid legacy one-vow records; retain unique facts and service location. |
| `app` ReliabilityJournal | 2 | 3 | Retain IDs, owners, revisions, destinations, notices; add linked capability and series-scoped guard metadata. |
| Extension attempt file | Absent | 1 | New small service-bound record; no speculative vow. |

Local schema 2 also contains recent-log entries with session ID, owner, and durable acceptance
time for the one-minute guard. Derive root scope from the owner. Use the logical local store plus
root as the gate scope; there is no remote service instance. For schema-1 migration, reconstruct
still-recent entries from active facts' log times using the existing clock/time interpretation,
not their performed times. Validate entries and apply existing expiry after decoding; deletion
removes/suppresses the corresponding guard. Preserve them in backups and clear obsolete guards
under the existing expiry rule when restoring old data.


Legacy schema-1 remote counts are not authoritative linked progress. Existing recovery for an
unbound legacy outbox remains required; upgrading must not invent a service binding or match
operations by performed time. Read compatible version-2 journals explicitly, validate them, then
atomically write version 3. Missing membership can leave a guard's scope unresolved until refresh,
but cannot silently discard its session ID or bypass repeat confirmation.

Cache, journal, and extension attempt writes are separate atomic files. Their migration can be
interrupted: each version is independently recognized on relaunch, identity/owner fields remain
stable, and a capability is not enabled until all required migrations validate. Do not clear a
journal because its cache migration failed. Preserve readable cached practice while mutations
are blocked by recovery. A migrated old cache remains provisional until a feature-aware refresh;
it cannot establish that the server still has only one-member series.

FileStore extension creation adds the complete child and inherited history to one candidate
snapshot. Existing owner-only `counts` must be replaced with derived contribution counts or
rebuilt in-memory counts from the shared helper after every successful mutation. No persisted
counts are added. Its actor/main-thread mutation boundary prevents source/history races.

Export feature schema 2 for local backups. Import schema 1 by explicit migration; import schema 2
as a whole linked collection after validation. Reject unknown versions and malformed links before
offering replacement confirmation. Preserve the existing damaged-original recovery behavior.
Remote caches are not interchangeable with local backups, and this feature adds no cross-app
or server data import/export endpoint.
