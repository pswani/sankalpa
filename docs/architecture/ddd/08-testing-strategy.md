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

Do not test domain events, event handlers, projections, session editing, per-sankalpa timezones, or
prorated session requirements because those concepts are outside the requirements. Session
deletion is in scope and is covered at the application, adapter, and behavioral levels because it
does not add domain behavior to `Session`.

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
- return the existing session for an exact replay of a logging action,
- reject reuse of a session identity with different content,
- delete a session idempotently and leave all derived reads to recompute from remaining sessions.

## Adapter Tests

Keep these narrow:

- Controller request validation and error mapping.
- Persistence round trips for `Sankalpa`, lifecycle transitions, and sessions.
- Exact session-create replay produces one row even when requests overlap.
- A replay after lifecycle state changes still returns the originally accepted session.
- Two different IDs at the same occurrence time produce two sessions.
- Reusing an ID with different content is rejected without mutation.
- Session deletion removes the row and records its tombstone atomically; repeated deletion
  succeeds, and a delayed create with the deleted ID cannot recreate it.
- Schema assertion that `endDate` is not stored if the design keeps it derived.
- Read adapter returns flat rows without constructing aggregates.
- Persistence concurrency test starts an uncommitted Pause, then attempts to log a session whose
  `occurredAt` follows the Pause's effective time. It proves the session waits for or conflicts with
  the lifecycle write and is not committed against the old In progress snapshot. The test uses at
  least two database connections so pool serialization cannot satisfy the assertion by itself.
- Period outcome query expands the session read to the selected windows' actual boundaries.
- The client pending-operation envelope migrates the legacy create-only format, atomically replaces
  an undone create with a deletion, and survives relaunch and failed delivery.
- Count overlays remove a pending create exactly once and subtract a known server session exactly
  once, including when the latter is older than the bounded snapshot.
- Paginated history can reach and delete a session outside the normal snapshot date range.
- Interaction tests cover the in-flight guard, one-minute repeat confirmation, accepted and pending
  result text, Undo, history deletion, and rejection recovery.

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

Scenario: Retrying one logging action does not duplicate a session
  Given a logging action whose first response was lost
  When the same logging action is delivered again
  Then exactly one session exists

Scenario: A rapid additional session is explicit
  Given a session was accepted or retained as pending less than one minute ago
  When the user tries to log another session for the same sankalpa
  Then the additional session requires confirmation
  And confirming records a distinct session

Scenario: Deleting a session corrects a closed period
  Given a closed period whose outcome includes a logged session
  When that session is deleted
  Then it no longer appears in session history or totals
  And the closed period outcome is recalculated from the sessions that remain

Scenario: Undo survives uncertain delivery
  Given a logging request may have reached the service before its response was lost
  And the session is shown as pending
  When the user undoes it
  Then the session is excluded immediately
  And delayed delivery of the original logging action cannot make it reappear
```

Do not use Cucumber unless readable business scenarios are worth the added tool. Plain integration
tests are fine.
