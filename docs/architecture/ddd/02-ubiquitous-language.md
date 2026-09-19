# 02 — Ubiquitous Language

Use requirement terms directly. Introduce a new term only when the requirements imply a concept but
do not give it a name.

## Terms

| Term | Source | Meaning | Code name |
|---|---|---|---|
| Sankalpa | Requirement | A declaration of intent with a commitment to perform an action. | `Sankalpa` |
| Commitment | Requirement | Start date, optional duration, action type, period, and number of times. | `Commitment` |
| Title | Requirement | Name of the sankalpa. | `Title` |
| Description | Requirement | Descriptive text for the sankalpa. | `Description` |
| Action type | Requirement | Meditation, Pranayama, Physical Activity, or Observance. | `ActionType` |
| Period | Requirement | Day, Week, Month, or Year. | `PeriodUnit` |
| Number of times | Requirement | Minimum performed sessions needed for one period. | `TimesPerPeriod` |
| Duration | Requirement | Optional count of periods. | `PeriodCount` |
| End date | Requirement | Derived from start date and duration; absent without duration. | `Commitment.endDate()` |
| Session | Requirement | One occasion logged as Performed or Missed. | `Session` |
| Status | Requirement | Performed or Missed; defaults to Performed. | `SessionStatus` |
| Lifecycle state | Requirement | Not started, In progress, Paused, Completed Successfully, Completed Unsuccessfully, Stopped. | `LifecycleState` |
| Lifecycle transition | Requirement | A user-performed change from one lifecycle state to another. | `LifecycleTransition` |
| Lifecycle timeline | Design term | Ordered transition history; satisfies the audit-log requirement. | `LifecycleTimeline` |
| Period window | Design term | One concrete occurrence of a period from the start date. | `PeriodWindow` |
| Period outcome | Design term | Derived result for one period: required, performed, missed count, standing. | `PeriodOutcome` |

## Verbs

| Verb | Meaning | Use case |
|---|---|---|
| Declare | Create a sankalpa in Not started. | `DeclareSankalpa` |
| Begin | Move Not started to In progress. | `BeginSankalpa` |
| Pause | Move In progress to Paused. | `PauseSankalpa` |
| Resume | Move Paused to In progress. | `ResumeSankalpa` |
| Complete | Move to Completed Successfully or Completed Unsuccessfully. | `CompleteSankalpa` |
| Stop | Move to Stopped. | `StopSankalpa` |
| Log | Record a performed or missed session. | `LogSession` |

There is no generic `updateStatus` use case because lifecycle changes are user intentions with
different allowed transitions.

## Deliberately Absent Terms

These words should stay out of the domain model until the requirements introduce them:

- `UserId`, `Owner`, `Account`, `Practitioner`
- `Activity`, `Practice`, `PracticeCatalog`
- `Reminder`, `Notification`, `Nudge`
- `Streak`, `Score`, `ProgressPercentage`
- `DomainEvent`, `IntegrationEvent`, `EventHandler`
- `Specification` suffixes for simple predicates

The examples in the requirements, such as Vipassana and Gym, remain examples. They are not catalogue
entries unless the requirements make them data.
