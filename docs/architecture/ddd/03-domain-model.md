# 03 — Domain Model

The model follows the current requirements and accepted design decisions. Unresolved questions in
[09-open-questions.md](09-open-questions.md) remain outside the design.

## Overview

```mermaid
classDiagram
  class Sankalpa {
    <<Aggregate Root>>
    +SankalpaId id
    +Title title
    +Description description
    +ActionType actionType
    +Commitment commitment
    +LifecycleTimeline lifecycle
    +declare(...)
    +begin(timing)
    +pause(now)
    +resume(now)
    +complete(outcome, now)
    +stop(now)
    +logSession(occurredAt, now) Session
    +state() LifecycleState
    +endDate() Optional~LocalDate~
  }

  class Session {
    <<Recorded Fact>>
    +SessionId id
    +SankalpaId sankalpaId
    +LocalDateTime occurredAt
    +LocalDateTime loggedAt
  }

  class Commitment {
    <<Value Object>>
    +LocalDate startDate
    +PeriodUnit periodUnit
    +TimesPerPeriod timesPerPeriod
    +Optional~PeriodCount~ periodCount
    +endDate() Optional~LocalDate~
    +covers(date) boolean
    +windowContaining(date) PeriodWindow
  }

  class LifecycleTimeline {
    <<Value Object>>
    +LifecycleState current
    +List~LifecycleTransition~ transitions
    +wasInProgressAt(at) boolean
    +wasPausedThroughout(window) boolean
    +canTransitionTo(target) boolean
  }

  class PeriodOutcomeCalculator {
    +tally(commitment, lifecycle, sessions, range, today) List~PeriodOutcome~
  }

  Sankalpa *-- Commitment
  Sankalpa *-- LifecycleTimeline
  Sankalpa ..> Session : creates after checking rules
  PeriodOutcomeCalculator ..> Commitment
  PeriodOutcomeCalculator ..> Session
  PeriodOutcomeCalculator ..> LifecycleTimeline
```

`Sankalpa` owns the rules about the commitment and lifecycle. `Session` is separate so the history
can grow without making the sankalpa aggregate unbounded.

## Aggregate: Sankalpa

```java
public final class Sankalpa {
    private final SankalpaId id;
    private final LocalDateTime declaredAt;
    private Title title;
    private Description description;
    private ActionType actionType;
    private Commitment commitment;
    private LifecycleTimeline lifecycle;

    public static Result<Sankalpa, DeclarationError> declare(Declaration declaration);

    public Result<Void, LifecycleTransitionError> begin(BeginTiming timing);
    public Result<Void, LifecycleTransitionError> pause(LocalDateTime now);
    public Result<Void, LifecycleTransitionError> resume(LocalDateTime now);
    public Result<Void, LifecycleTransitionError> complete(
        CompletionOutcome outcome, LocalDateTime now);
    public Result<Void, LifecycleTransitionError> stop(LocalDateTime now);

    public Result<Session, SessionNotLoggable> logSession(
        SessionId sessionId,
        LocalDateTime occurredAt,
        LocalDateTime now
    );
}
```

Session deletion is not a method on `Sankalpa`. Removing a session does not change commitment or
lifecycle state and introduces no aggregate invariant; the `DeleteSession` application use case
removes the identified session through `SessionRepository`.

## Aggregate/Record: Session

```java
public final class Session {
    private final SessionId id;
    private final SankalpaId sankalpaId;
    private final LocalDateTime occurredAt;
    private final LocalDateTime loggedAt;
}
```

A session records a past fact while it is part of the practice. It has no behavior beyond
construction-time validity. The correction requirement permits that fact to be permanently
removed; it does not make the remaining session mutable.

`Sankalpa.logSession(...)` creates sessions so the lifecycle and commitment rules stay with the
object that knows them.

## Session Identity, Retry, and Correction

`SessionId` also identifies the logging action that first requested the session. The application
must preserve that identity across delivery retries. Before asking the aggregate to create a
session, `LogSession` checks for an existing record with that ID:

- An active session with the same ID, sankalpa, and `occurredAt` is a successful replay and returns
  the existing session.
- An active session with the same ID and different content is rejected as
  `SessionIdentityConflict`.
- A tombstoned ID is already consumed: the same sankalpa receives `SessionDeleted`, while a
  different sankalpa receives `SessionIdentityConflict`.
- A new ID is validated by `Sankalpa.logSession(...)` and persisted once.

The replay check happens before current lifecycle validation. A response may be lost after a valid
session commits, and retrying that action after the sankalpa changes state must return the original
session rather than reinterpret the old action under new state.

There is deliberately no uniqueness rule on `(sankalpaId, occurredAt)`. Separate confirmed
logging actions may represent separate performed sessions at the same timestamp.

`DeleteSession` permanently removes the identified session. It is idempotent for an already absent
session. A small persistence tombstone for the deleted `SessionId` prevents an earlier or delayed
delivery of that logging action from recreating the session. The tombstone is delivery metadata,
not a retained session or lifecycle audit fact; it carries no performed-session details and never
participates in queries or outcomes.

Because period outcomes are derived, deleting a session automatically changes the performed and
missed counts of any affected open or closed period the next time it is evaluated.

## Value Object: Commitment

```java
public record Commitment(
    LocalDate startDate,
    PeriodUnit periodUnit,
    TimesPerPeriod timesPerPeriod,
    Optional<PeriodCount> periodCount
) {
    public Optional<LocalDate> endDate();
    public boolean covers(LocalDate date);
    public Optional<PeriodWindow> windowContaining(LocalDate date);
    public List<PeriodWindow> windowsStartingBetween(LocalDate from, LocalDate until);
}
```

`PeriodCount` means duration is represented only as a whole number of periods. That directly follows
the requirement and avoids representing invalid duration shapes.

`endDate()` is inclusive. For a commitment of `n` periods, it is the start of period `n + 1` minus
one day. For example, one DAY beginning January 1 ends January 1, and one WEEK beginning January 1
ends January 7. Every boundary is calculated from the original start date plus its period index,
not by advancing the previously adjusted boundary. A January 31 monthly commitment therefore has
boundaries on January 31, February 28 (or 29), March 31, and April 30 rather than drifting to the
28th. `covers(date)` and `PeriodWindow` use the same inclusive boundary.

## Lifecycle

```java
public enum LifecycleState {
    NOT_STARTED,
    IN_PROGRESS,
    PAUSED,
    COMPLETED_SUCCESSFULLY,
    COMPLETED_UNSUCCESSFULLY,
    STOPPED
}

public record LifecycleTransition(
    LifecycleState from,
    LifecycleState to,
    LocalDateTime effectiveAt,
    LocalDateTime recordedAt
) {}

public record BeginTiming(
    LocalDateTime effectiveAt,
    LocalDateTime recordedAt
) {}

public record LifecycleTimeline(
    LifecycleState current,
    List<LifecycleTransition> transitions
) {}
```

Allowed transitions:

| From \ To | Not started | In progress | Paused | Completed successfully | Completed unsuccessfully | Stopped |
|---|---|---|---|---|---|---|
| Not started | - | yes | no | yes | yes | yes |
| In progress | no | - | yes | yes | yes | yes |
| Paused | no | yes | - | yes | yes | yes |
| Completed successfully | no | no | no | - | no | no |
| Completed unsuccessfully | no | no | no | no | - | no |
| Stopped | no | no | no | no | no | - |

The transition table is domain logic. It should live in `LifecycleState` or `LifecycleTimeline`, not
in controllers or SQL.

`effectiveAt` is when the lifecycle change took effect; `recordedAt` is when the user performed and
recorded it. Only Begin may have different values. Its effective time may be in the past, but not
before the commitment start or in the future. Pause, Resume, Complete, and Stop always use the
clock's current time for both values. Because the only backdated transition is the first transition,
later lifecycle changes cannot rewrite the eligibility of a session accepted by an earlier,
committed command. No historical cross-aggregate transition policy or latest-session lookup is
needed. Concurrent session and lifecycle commands still need a single commit order at the
persistence boundary so neither validates against a stale lifecycle snapshot.

Reaching a finite commitment's end date does not change lifecycle state. Commitment coverage and
lifecycle answer different questions: coverage says whether a timestamp belongs to the commitment;
lifecycle says whether action was active at that timestamp. A session is eligible only when both
are true.

## Period Outcomes

```java
public record PeriodOutcome(
    PeriodWindow window,
    int required,
    int performed,
    int missed,
    PeriodStanding standing
) {}

public enum PeriodStanding {
    OPEN,
    PAUSED,
    SATISFIED,
    UNSATISFIED
}
```

Period outcomes are derived, not stored.

For a closed, non-paused period, performed sessions determine the arithmetic:

```java
boolean satisfied = performed >= required;
int missed = Math.max(0, required - performed);
```

A window is `PAUSED` only when the sankalpa was Paused for the entire window. Otherwise an unclosed
window is `OPEN`; a closed window is `SATISFIED` or `UNSATISFIED`. A partially paused window keeps
its original boundaries and full requirement, and tracking resumes within that same window. There
is no proration or end-date extension. A fully Paused period is not evaluated as satisfied or
unsatisfied, and its derived `missed` value is zero.

For a finite commitment that reaches its end date, all of its closed period windows may be
evaluated even if lifecycle remains In progress. Completed or Stopped is always a reporting cutoff:
only complete windows ending before that transition are evaluated. The interrupted window and all
later windows are omitted. Session history remains available independently of period outcomes.

The calculator evaluates only windows whose start dates fall in the requested date range. The
application loads sessions from the first selected window's start through the last selected
window's end, so a range that begins partway through a week or month cannot undercount that window.
This keeps an indefinite daily commitment from loading and materializing its entire history for
every query.

## Invariants

| # | Invariant | Enforced by |
|---|---|---|
| S1 | Title is present and not blank. | `Title` |
| S2 | Action type is one of the four requirement values. | `ActionType` |
| S3 | Start date is no more than one year before today. | `Sankalpa.declare` |
| S4 | Times per period is positive. | `TimesPerPeriod` |
| S5 | Duration, when present, is a whole number of periods. | `PeriodCount` on `Commitment` |
| S6 | End date is derived, inclusive, and not stored. | `Commitment.endDate()` |
| S7 | Lifecycle transitions follow the allowed table. | `LifecycleState` / `LifecycleTimeline` |
| S8 | Lifecycle transitions record both effective and recorded time. | `LifecycleTimeline` |
| S9 | A session may be logged only for a past moment. | `Sankalpa.logSession` |
| S10 | A session may be logged only within commitment coverage and while the sankalpa was In progress. | `Sankalpa.logSession` using `Commitment` and `LifecycleTimeline` |
| S11 | A backdated Begin is not future-effective or before the commitment start. | `LifecycleTimeline` |
| S12 | Missed count is derived from required minus performed and cannot be negative. | `PeriodOutcomeCalculator` |
| S13 | A partially paused period is evaluated normally; a fully paused period is reported as Paused. | `PeriodOutcomeCalculator` |
| S14 | Only Begin may be backdated; all other transitions take effect when recorded. | `LifecycleTimeline` |
| S15 | Reaching the end date does not automatically change lifecycle state. | `Sankalpa` / application behavior |
| S16 | A terminal transition excludes the interrupted and later windows from evaluation. | `PeriodOutcomeCalculator` |
| S17 | Replaying one logging action cannot create another session. | `LogSession` and stable `SessionId` |
| S18 | Separate confirmed logging actions remain distinct even at the same performed time. | Session identity; no timestamp uniqueness rule |
| S19 | A deleted session is absent from history, totals, and period outcomes and cannot be recreated by delayed delivery of its old logging action. | `DeleteSession`, `SessionRepository`, deletion tombstone |

## Domain Errors

Use domain errors for business refusals:

- `InvalidTitle`
- `UnknownActionType`
- `InvalidTimesPerPeriod`
- `InvalidPeriodCount`
- `StartDateTooFarInPast`
- `LifecycleTransitionError`
  - `InvalidLifecycleTransition`
  - `TransitionInFuture`
  - `TransitionBeforeStart`
- `SessionInFuture`
- `SessionOutsideCommitment`
- `SankalpaNotInProgressAtThatTime`
- `SankalpaNotFound`
- `InvalidCompletionOutcome`

These errors do not know HTTP status codes. Controllers map them to transport responses.

`SessionIdentityConflict` and `SessionDeleted` are application command outcomes, not domain errors.
They arise while resolving stable delivery identity before a new session reaches domain validation.
