# 06 — Hexagonal Architecture

Use ports and adapters to keep domain rules independent from HTTP, persistence, and the system
clock. Keep the implementation shape small until the project needs more.

## Recommended Package Shape

A single application module is enough to start:

```text
src/main/java/com/sankalpa/
  domain/
    Sankalpa.java
    Session.java
    SankalpaId.java
    SessionId.java
    Title.java
    Description.java
    ActionType.java
    commitment/
      Commitment.java
      PeriodUnit.java
      PeriodCount.java
      TimesPerPeriod.java
      PeriodWindow.java
      PeriodOutcome.java
      PeriodStanding.java
      PeriodOutcomeCalculator.java
    lifecycle/
      LifecycleState.java
      LifecycleTimeline.java
      LifecycleTransition.java
      BeginTiming.java
      CompletionOutcome.java
    error/
      DomainError.java
      DeclarationError.java
      LifecycleTransitionError.java
      SessionNotLoggable.java
    shared/
      Result.java

  application/
    declare/
    begin/
    pause/
    resume/
    complete/
    stop/
    logsession/
    deletesession/
    query/
    port/

  adapter/
    in/web/
    out/persistence/
    out/clock/
```

Split into Gradle modules later if package boundaries start to erode. Starting with multiple modules
is optional, not a requirement.

## Dependency Rule

- `domain` depends on the JDK only.
- `application` depends on `domain`.
- `adapter` depends on `application` and framework libraries.
- Domain classes do not use Spring, Jackson, validation annotations, ORM annotations, SQL, or HTTP.

ArchUnit can enforce this even in a single module.

```java
@ArchTest
static final ArchRule domain_is_framework_free =
    noClasses().that().resideInAPackage("..domain..")
        .should().dependOnClassesThat()
        .resideInAnyPackage("org.springframework..", "jakarta.persistence..",
                            "jakarta.validation..", "com.fasterxml.jackson..");
```

## Persistence

Keep domain objects separate from persistence rows when doing so protects the model:

- `Commitment` may persist as several columns.
- `LifecycleTimeline` may persist as transition rows.
- `endDate` should not be stored if it is derived from commitment fields.

Sketch:

| Table | Holds |
|---|---|
| `sankalpa` | id, title, description, action type, start date, period unit, times per period, period count, current state, declared at |
| `sankalpa_lifecycle_transition` | sankalpa id, sequence, from state, to state, effective at, recorded at |
| `session_identity` | globally unique session id, owning sankalpa id, `ACTIVE` or `DELETED` state |
| `practice_session` | id, sankalpa id, occurred at, logged at; only active facts |
| `service_metadata` | persistent service instance identity used for safe client capability binding |

`session_identity` is not an event or audit table. Both create and delete contend on its primary
key, which prevents the same UUID from being active under one sankalpa and deleted under another.
Deleting physically removes `practice_session` and changes the ledger state in one transaction.

An idempotent migration backfills every existing practice session as `ACTIVE` before writes are
served. Startup fails on incomplete or contradictory backfill. Do not add event tables, server
outbox tables, projection tables, account ownership columns, activity tables, or timezone columns
until the requirements call for them.

## Read Side

Simple list/detail/session/history queries can use flat read rows through `SankalpaReadPort`.

`GetPeriodOutcomes` should select windows from the requested `from`/`until` range, query sessions
from the first selected window's start through the last selected window's end, and use the domain
calculator instead of reimplementing period arithmetic in SQL. Range-bounded queries are sufficient
for current scale; no projection table is needed.

## Adapter Notes

- Controllers map request data to commands and domain errors to HTTP responses.
- Persistence adapters map rows to domain objects and back.
- Persistence uses ordinary optimistic concurrency on `Sankalpa` lifecycle changes. While logging
  a session, the adapter locks the parent sankalpa row before loading and validating its lifecycle
  snapshot, or performs an equivalent atomic version check. This only orders overlapping commands;
  it does not query session history or support backdated lifecycle changes. Without that ordering,
  an uncommitted Pause can have an effective time before a session's `occurredAt` while the session
  command still reads the old In progress state.
- The session-identity primary key orders same-ID creates/deletes even when callers name different
  sankalpas. A recognized claim collision rolls back and reruns the identity decision against the
  winner; unrelated integrity failures are not retried.
- Exact replay is resolved before calling `Sankalpa.logSession`, so a later lifecycle change does
  not invalidate an already accepted command.
- Session read adapters return active facts only. Deletion therefore changes both open and closed
  derived outcomes without special calculator logic.
- The clock adapter supplies `now()` and `today()` so tests can control time.
- The configured application timezone converts lifecycle/session timestamps to the dates used by
  commitment windows; no per-user or per-sankalpa timezone is modeled.
- There is no event adapter in the current design.

## Client Reliability Adapter

The iOS operation journal is a driven adapter around unreliable network delivery. It contains one
pending create or delete per session identity, recent-log guards, and unacknowledged reconciliation
notices. It is atomically persisted and scoped to the originating persistent service instance,
independent of that service's current network location. Corrupt or unbound legacy journals fail
closed: reads remain available, but session mutation and delivery stop until explicit recovery.

The client snapshot is a read model, not a second authority:

```text
visible = (last server snapshot + pending creates by ID) - pending deletes by ID
```

All client totals and period calculations use this visible set. Server-accepted mutations are
persisted into the base snapshot before the corresponding operation is removed, preventing a
failed refresh or relaunch from reversing accepted state. The complete session collection, rather
than a separately cached count, supplies every total. Operation revisions ensure a late response
cannot remove a newer Undo/delete operation.
