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
| End date | Requirement | Inclusive last date covered by a finite commitment; absent without duration. | `Commitment.endDate()` |
| Session | Requirement | One occasion on which the intended action was performed. | `Session` |
| Linked series | Requirement | An original vow and its progressively longer explicit extensions. | Immutable `seriesId` on `Sankalpa` |
| Extension | Requirement | A new, longer vow preserving its source as a separate commitment. | `Sankalpa.extend`, `extensionOf` |
| Logging owner | Design term | The vow through which a session was originally logged; retained for command identity and deletion. | `Session.sankalpaId` |
| Contribution | Design term | A session counting toward a same-series vow eligible at the performed time. | Series membership plus `acceptsPerformedAt` |
| Inherited transition | Requirement/design term | A copied lifecycle transition retaining its original vow and timestamps. | `LifecycleTransition.originSankalpaId` |
| Completion achievement | Requirement | A separately visible vow marked Completed - Successfully by the user. | Derived from that vow's terminal transition |
| Logging action | Requirement | One user intention to record one session; all delivery attempts for it share one identity. | `LogSession` command identified by `SessionId` |
| Session identity | Design term | Stable UUID that identifies both the logging action and resulting session. | `SessionId` |
| Replay | Design term | Repeating the same logging command identity and values after an uncertain result. | `SessionLogResult.created == false` |
| Pending operation | Requirement/design term | A create or delete durably retained on the device until the service decision is safely reflected locally. | `PendingSession` or `PendingSessionDeletion` |
| Undo | Requirement | Immediate deletion of the exact session just logged. | `DeleteSession` with a `SessionReceipt` |
| Delete | Requirement | Permanently remove a logged session and prevent its identity from reappearing. | `DeleteSession` |
| Repeat confirmation | Requirement | Confirmation required before another logging action in the same linked series within one minute. | Client interaction policy |
| Lifecycle state | Requirement | Not started, In progress, Paused, Completed Successfully, Completed Unsuccessfully, Stopped. | `LifecycleState` |
| Lifecycle transition | Requirement | A user-performed state change recorded for audit. Begin may be backdated; every other transition takes effect when performed. | `LifecycleTransition` |
| Begin timing | Design term | Effective and recorded timestamps for the transition from Not started to In progress. | `BeginTiming` |
| Lifecycle timeline | Design term | Transition history that satisfies the audit-log requirement and reconstructs state at a time. | `LifecycleTimeline` |
| Paused interval | Requirement | Time from Pause until the next Resume, Completed, or Stopped transition. | Derived from `LifecycleTimeline` |
| Period window | Design term | One inclusive concrete occurrence of a period from the start date. | `PeriodWindow` |
| Period outcome | Design term | Derived result for one period: required, performed, missed shortfall, and standing. | `PeriodOutcome` |
| Paused period | Design term | A period whose entire window was in the Paused state; reported without satisfaction or missed arithmetic. | `PeriodStanding.PAUSED` |

## Verbs

| Verb | Meaning | Use case |
|---|---|---|
| Declare | Create a sankalpa in Not started. | `DeclareSankalpa` |
| Extend | Create a longer, linked vow with inherited history and its source's current state. | `ExtendSankalpa` |
| Begin | Move Not started to In progress at a supplied effective time. | `BeginSankalpa` |
| Pause | Move In progress to Paused now. | `PauseSankalpa` |
| Resume | Move Paused to In progress now. | `ResumeSankalpa` |
| Complete | Move to Completed Successfully or Completed Unsuccessfully now. | `CompleteSankalpa` |
| Stop | Move to Stopped now. | `StopSankalpa` |
| Log | Record a performed session. | `LogSession` |
| Undo | Immediately delete the exact session receipt returned by logging. | `DeleteSession` |
| Delete | Permanently remove a selected session. | `DeleteSession` |

A session is eligible only when its `occurredAt` is covered by the commitment and the lifecycle
state at that time is In progress.

Logging eligibility is validated when a new identity is created. Contribution reads also use
performed-time eligibility for each target vow, without creating another session. An exact replay returns the already
accepted session even if the sankalpa's lifecycle has since changed. Two sessions may have the same
`occurredAt`; identity, not time proximity, distinguishes them.

There is no generic `updateStatus` use case because lifecycle changes are user intentions with
different allowed transitions.

## Deliberately Absent Terms

These words should stay out of the domain model until the requirements introduce them:

- `UserId`, `UserOwner`, `Account`, `Practitioner` (the application is single-user;
  a session's logging owner identifies a vow, not a person)
- `Activity`, `Practice`, `PracticeCatalog`
- `Reminder`, `Notification`, `Nudge`
- `Streak`, `Score`, `ProgressPercentage`
- `DomainEvent`, `IntegrationEvent`, `EventHandler`
- `Specification` suffixes for simple predicates
- `SoftDeletedSession`, `SessionRevision`, `SessionAuditHistory`

The examples in the requirements, such as Vipassana and Gym, remain examples. They are not catalogue
entries unless the requirements make them data.
