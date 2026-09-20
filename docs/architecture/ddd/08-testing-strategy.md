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

Do not test domain events, event handlers, projections, edit/delete behavior, per-sankalpa
timezones, or prorated session requirements because those concepts are outside the requirements.

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

## Adapter Tests

Keep these narrow:

- Controller request validation and error mapping.
- Persistence round trips for `Sankalpa`, lifecycle transitions, and sessions.
- Schema assertion that `endDate` is not stored if the design keeps it derived.
- Read adapter returns flat rows without constructing aggregates.
- Persistence concurrency test starts an uncommitted Pause, then attempts to log a session whose
  `occurredAt` follows the Pause's effective time. It proves the session waits for or conflicts with
  the lifecycle write and is not committed against the old In progress snapshot.
- Period outcome query expands the session read to the selected windows' actual boundaries.

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
```

Do not use Cucumber unless readable business scenarios are worth the added tool. Plain integration
tests are fine.
