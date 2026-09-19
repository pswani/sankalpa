# 08 — Testing Strategy

Test the domain rules heavily and the architecture lightly. Do not add testing machinery for
features that are not in scope.

## Domain Tests

Focus on behavior:

- `Commitment` derives period windows and end date from start date, period unit, and duration.
- `Commitment` rejects or cannot represent invalid period counts.
- `LifecycleState` allows exactly the transitions in the requirements.
- `LifecycleTimeline` records transitions in order.
- `Sankalpa.declare` rejects a start date more than one year in the past.
- `Sankalpa.logSession` rejects future sessions.
- `Sankalpa.logSession` rejects sessions outside the commitment.
- `Sankalpa.logSession` rejects sessions when the sankalpa was not In progress.
- `PeriodOutcomeCalculator` treats number of times as a minimum.
- `PeriodOutcomeCalculator` derives missed count from required and performed sessions.

Do not test domain events, event handlers, projections, edit/delete behavior, per-sankalpa
timezones, or paused-period exemptions unless those concepts enter the requirements.

## Application Tests

Use in-memory fakes for repositories and the clock.

Verify that use cases:

- load the aggregate,
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
```

Do not use Cucumber unless readable business scenarios are worth the added tool. Plain integration
tests are fine.
