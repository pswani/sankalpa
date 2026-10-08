# 08 — Testing Strategy

Test the domain rules heavily and the architecture lightly. Do not add testing machinery for
features that are not in scope.

## Domain Tests

Focus on behavior:

- `Commitment` derives inclusive period windows and end date from start date, period unit, and
  duration, including day/week/month/year boundary cases.
- Month and year boundaries are independently anchored to the original start date, including
  January 31 and February 29 cases, and do not drift after a shortened month or non-leap year.
- `Commitment` rejects or cannot represent invalid period counts.
- `LifecycleState` allows exactly the transitions in the requirements.
- `LifecycleTimeline` records transitions in order.
- `LifecycleTimeline` accepts a past effective time for Begin but rejects a future or pre-start
  Begin.
- `LifecycleTimeline` makes Pause, Resume, Complete, and Stop effective at their recorded time.
- `LifecycleTimeline` retains distinct effective and recorded timestamps for a backdated Begin.
- `Sankalpa.declare` rejects a start date more than one year in the past.
- `Sankalpa.logSession` rejects future sessions.
- `Sankalpa.logSession` rejects sessions outside the commitment.
- `Sankalpa.logSession` rejects sessions when the sankalpa was not In progress.
- `Sankalpa.logSession` accepts a past session covered by a backdated In progress transition.
- `PeriodOutcomeCalculator` treats number of times as a minimum.
- `PeriodOutcomeCalculator` derives missed count from required and performed sessions.
- `PeriodOutcomeCalculator` evaluates a partially paused window normally without proration.
- `PeriodOutcomeCalculator` reports a fully paused window as `PAUSED`, with no missed shortfall.
- Reaching a finite end date does not change lifecycle state.
- A terminal transition excludes the interrupted and later period windows.
- A period-outcome date range generates only windows starting in the range and counts every session
  in those complete windows.

Do not test server domain events, event handlers, projections, session editing, per-sankalpa
timezones, or prorated session requirements because those concepts are outside the requirements.
Session deletion is tested through application and adapter behavior; it does not add a deleted
state to the domain `Session`.

## Application Tests

Use in-memory fakes for repositories and the clock.

Verify that use cases:

- load the aggregate,
- accept optional `effectiveAt` only for Begin,
- use the application clock as both effective and recorded time for every other transition,
- call the aggregate method,
- save on success,
- return domain errors unchanged,
- do not duplicate lifecycle rules.

For session reliability, verify that use cases:

- create a new session only for an absent identity;
- return an exact replay without rechecking a later lifecycle state;
- reject identity reuse with a different parent or performed-at value;
- allow two different identities with the same performed-at value;
- make first and repeated deletion succeed;
- make delete-before-create prevent every delayed creation;
- recalculate both open and closed period outcomes after deletion.

## Adapter Tests

Keep these narrow:

- Controller request validation and error mapping.
- Persistence round trips for `Sankalpa`, lifecycle transitions, and sessions.
- Session-identity ledger migration backfills existing facts and is safe on repeated startup.
- Ledger consistency: active identities have one fact; deleted identities have none.
- Controller/OpenAPI contract covers matching body/header identity, mismatch rejection, the
  temporary legacy path, `201` create, `200` replay, `204` delete, `409` identity conflict, and
  `410` permanently deleted.
- Capability contract advertises identity version 1 and a persistent service instance ID; a client
  facing a missing/older capability sends no session mutation.
- Every identified mutation requires the expected service instance and an instance mismatch is
  rejected before parent lookup or any database change.
- Service identity initialization is concurrency-safe, stable across restart and address change,
  and different for a fresh or intentionally forked data store.
- Schema, backfill, verifier, metadata restart, and sequential decision tables run against
  production SQLite as well as H2; overlapping races use at least two real connections rather than
  passing through pool serialization.
- Schema assertion that `endDate` is not stored if the design keeps it derived.
- List/detail/audit read adapters return flat rows; contribution queries use the shared domain
  eligibility predicate rather than duplicating it in SQL.
- Persistence concurrency test starts an uncommitted Pause, then attempts to log a session whose
  `occurredAt` follows the Pause's effective time. It proves the session waits for or conflicts with
  the lifecycle write and is not committed against the old In progress snapshot. The test uses at
  least two database connections so pool serialization cannot satisfy the assertion by itself.
- Period outcome query expands the session read to the selected windows' actual boundaries.
- Concurrent identical creates result in one creation and one replay.
- Same-ID create/delete and cross-parent races resolve to one owner and one ledger state, never an
  active fact plus a deleted identity.

## iOS Reliability Tests

Use deterministic transport and clock fakes. Verify:

- a create is durable before its first request and every retry sends its stable ID;
- pending create/delete and recent-repeat state survive relaunch;
- Undo atomically replaces create with delete and never later sends that create;
- pending deletion is excluded from history, totals, open/closed outcomes, and missed counts;
- accepted create/delete remains applied after a failed refresh and relaunch;
- a `2xx` followed by cache-write failure retains the journal operation and converges without
  duplicating or resurrecting a session;
- Undo during an in-flight create retains the newer delete when the create response arrives;
- a refresh started for an old service binding cannot publish after a verified relocation;
- a refresh started before an accepted create/delete cannot publish its older same-service snapshot;
- rejected pending create corrects the overlay; a delete refusal restores the unchanged cached
  session, and each leaves one durable notice;
- if that correction cannot be persisted, the operation remains pending and no false rejection or
  notice is reported;
- indeterminate transport/5xx/malformed responses and exhausted transient conflicts keep the
  operation, while stable business/identity refusals remove it;
- current same-time operations reconcile by ID; legacy operations are preserved but never matched
  or sent until the user explicitly discards them;
- an address change is refused while session operations are pending, so an operation cannot move to
  another instance, including one reusing the previous address;
- address reuse after capability verification is still stopped by per-mutation instance binding;
- corrupt and unconfirmed-legacy journals preserve their data and block mutation/delivery until an
  explicit recovery decision;
- unreadable or legacy bytes remain in place across relaunch, keeping recovery mode active until an
  explicit warned discard, and concurrent journal transitions cannot consume a newer revision;
- deletes flush first, and an unreachable response preserves the remainder;
- connectivity restoration and scheduled active-app retry resume pending commands automatically;
- complete history reads every validated page and can delete a session beyond the former ten-page
  cap;
- the repeat guard is per linked series (self for unrelated vows), persists, expires at 60 seconds,
  and confirmation creates a new
  identity;
- all logging entry points share one processing gate;
- all totals derive from the overlaid complete session set rather than an independent cached count.

## Architecture Tests

Use ArchUnit to enforce:

- Domain does not depend on application or adapters.
- Domain does not depend on Spring, Jackson, validation, ORM, SQL, or HTTP.
- Application does not depend on adapters.

These tests are valuable because they protect the one architectural boundary that matters here.

## Behavioral Specs

A small number of end-to-end scenarios is enough:

```gherkin
Scenario: Performing more often than committed still satisfies the period
  Given a sankalpa committed to 2 times per DAY
  And the sankalpa is In progress
  When 3 sessions are logged as Performed in that day
  And the period has ended
  Then the period is SATISFIED

Scenario: Sessions not logged as performed count as missed
  Given a sankalpa committed to 4 times per WEEK
  And the sankalpa is In progress
  When 1 session is logged as Performed in the first week
  And the week has ended
  Then the period is UNSATISFIED with 3 missed sessions

Scenario: Pausing does not extend the end date
  Given a sankalpa with a fixed duration
  When the sankalpa is paused and later resumed
  Then the end date is unchanged

Scenario: A shortened month does not move later monthly boundaries
  Given a monthly sankalpa beginning January 31
  Then its next boundaries are February 28 or 29, March 31, and April 30

Scenario: Tracking resumes within a partially paused period
  Given a sankalpa is In progress for part of a weekly period
  And it is Paused and then resumed during that period
  When the period ends
  Then the original weekly boundary is unchanged
  And the full weekly requirement is evaluated normally

Scenario: A fully paused period is shown as paused
  Given a sankalpa is Paused for an entire period
  When the period ends
  Then the period standing is PAUSED
  And its missed shortfall is 0

Scenario: Begin and a session can be backdated
  Given a sankalpa whose start date was 3 months ago
  When it is moved to In progress effective on its start date
  And a session after that effective time is logged
  Then the session is accepted
  And the transition audit contains distinct effective and recorded times

Scenario: Reaching the end date does not complete the sankalpa
  Given an In progress sankalpa with a fixed duration
  When its end date passes
  Then all completed period windows are evaluated
  And the lifecycle state remains In progress

Scenario: Stopping early excludes a partial period
  Given an In progress sankalpa with a fixed duration
  When it is Stopped partway through a period
  Then periods ending before the Stop are evaluated
  And the interrupted period and later periods are not evaluated

Scenario: A lost logging response does not duplicate a session
  Given one logging action has a stable session identity
  When the service commits it but its response is lost
  And the client retries the action
  Then exactly one session exists

Scenario: A confirmed rapid repeat is a real second session
  Given a session was just accepted
  When the user attempts another log within the same linked series within one minute
  And confirms the repeat
  Then both sessions exist even if their performed-at times are identical

Scenario: Undo wins over uncertain delivery
  Given a logged session is pending because delivery is uncertain
  When the user chooses Undo
  Then the session is excluded immediately
  And a delayed create with that identity can never make it reappear

Scenario: Deleting a past session revises derived results
  Given a closed period contains a logged session
  When that session is permanently deleted
  Then it disappears from history and totals
  And the closed period's performed and missed values are recalculated
```

Do not use Cucumber unless readable business scenarios are worth the added tool. Plain integration
tests are fine.


## Linked Extension Verification

These are implementation acceptance checks, not a claim that implementation tests already exist.
Use the same calendar, clock, transport, and repository fakes plus real persistence race tests.

### Domain and application

- A 40-day vow extended to 90 days retains practice fields, original start, and history; the
  source remains unchanged. Paused sources produce Paused extensions.
- Reject indefinite, Not started, Completed, or Stopped sources; reject equal/shorter duration,
  non-whole periods, and a new end date before today. Accept a new end date of today.
- An inherited start older than one year is accepted only through extension, not declaration.
- Multi-step extensions preserve original transition timestamps and origins. Their own later
  transitions are independent, including a Pause or terminal action on a shorter vow.
- Existing sessions, late backfills, and sessions logged through either end of a series contribute
  to every eligible vow. Unrelated vows with identical practice fields never share sessions.
- A target that was Paused at the performed time excludes the contribution; logging through an
  ineligible owner is refused even if another member would accept it.
- Sessions after a shorter end date count only toward eligible longer vows. Terminal vows accept
  eligible past contributions without reopening or changing their chosen completion outcome.
- Each fact counts once per vow and once in combined totals; distinct same-time facts count twice.
- Per-vow history, lifetime counts, session contributor lists, and outcomes use the same predicate.
- Range expansion includes complete period windows. Filtered pagination cannot truncate history.
- Successful completion acknowledges only that vow and records a distinct achievement; refreshing
  or deleting a session does not repeat the completion action or alter terminal state.

### Persistence, identity, and races

- Two different extension requests for one source result in one child. An exact retry replays
  after the source changes state; a reused child ID with changed input conflicts.
- A failed creation leaves no child or copied history. Extension racing Pause/Resume/Complete
  sees one committed source state; command time is captured after the write guard is acquired.
- Session/lifecycle ordering remains correct when the commands address different series members.
  Identity races across unrelated series still resolve globally, including delete-before-create.
- Deleting a shared session from a non-owner view sends the immutable owner and changes every
  contributing count/history/outcome. Sending another owner directly still conflicts.
- A deletion racing extension creation cannot resurrect a fact or retain an independent copy.
- Existing data migrates to one-member series with unchanged session/ledger/service identities.
  Backups preserve links and provenance; invalid branches, cycles, foreign-series parents,
  incompatible practice fields, or malformed inherited history fail validation.
- Run schema and transaction checks against SQLite and the test database, plus local-file
  save/restore failure cases. Use genuine overlapping transactions for races.

### Clients and compatibility

- Pending create/delete affects every eligible cached vow; suppression and reversal use session
  identity globally. Relaunch, rejected operations, late responses, and cache-write failure retain
  the existing durability and Undo guarantees across the series.
- Logging through another linked vow while an action is processing cannot bypass the gate.
  Within one minute, switching vows requires repeat confirmation; unrelated roots do not.
- Recent guards survive extension, migration, and relaunch. Missing membership/timeline data
  disables linked offline logging until refreshed rather than guessing contributions.
- Lost extension responses retry the same persisted ID and request after relaunch, publish one
  child, and never retarget a different service. No speculative or partial vow appears.
- Linked capability, owner-bearing rows, and series-aware counts are negotiated together. An old
  server disables extension; an old mutation contract cannot write into a multi-member series.
  An upgrade-required response keeps pending work; negotiating the header never changes identity,
  owner, performed time, or service binding. A pending log racing extension creation is not lost.
- Partial refreshes with missing owners/members cannot replace the valid cached contribution view.
  Owner aliases remain compatible; old read contracts never present linked counts as owner counts.
- Restore validates inherited source prefixes, not equality to a source timeline that has diverged;
  equal-time transitions preserve sequence and provenance.
- Journey: log 30 days of a 40-day vow, extend to 90, finish the 40-day vow successfully, log through
  the extension after day 40, and later complete it successfully. Show two separate wins and a
  journal containing each performed session once.
