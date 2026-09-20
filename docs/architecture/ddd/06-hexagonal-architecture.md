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
| `session` | id, sankalpa id, occurred at, logged at |

Do not add event tables, outbox tables, projection tables, ownership columns, activity tables, or
timezone columns until the requirements call for them. Single-user scope is represented by the
absence of account and owner data, not by a synthetic singleton user row.

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
  a session, the adapter locks the parent sankalpa row (or performs an equivalent version check) so
  the lifecycle snapshot cannot change between validation and insert.
- The clock adapter supplies `now()` and `today()` so tests can control time.
- The configured application timezone converts lifecycle/session timestamps to the dates used by
  commitment windows; no per-user or per-sankalpa timezone is modeled.
- There is no event adapter in the current design.
