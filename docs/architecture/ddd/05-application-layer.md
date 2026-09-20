# 05 — Application Layer

The application layer coordinates use cases. It should load data, map input into domain values,
invoke domain behavior, save results, and return success or a domain error.

It should not duplicate lifecycle or commitment rules.

## Commands

Commands in current scope:

| Command | Purpose |
|---|---|
| `DeclareSankalpa` | Create a sankalpa in Not started. |
| `BeginSankalpa` | Move a sankalpa to In progress, optionally effective in the past. |
| `PauseSankalpa` | Move a sankalpa to Paused now. |
| `ResumeSankalpa` | Move a sankalpa back to In progress now. |
| `CompleteSankalpa` | Move a sankalpa to one of the completed states now. |
| `StopSankalpa` | Move a sankalpa to Stopped now. |
| `LogSession` | Record a past performed session. |

Not in current scope:

- `AmendSankalpa`
- `ReviseSankalpa`
- `DeleteSankalpa`
- session edit/delete use cases

Those should be added only when the requirements add them.

## Queries

Queries return data and change nothing:

| Query | Returns |
|---|---|
| `FindSankalpas` | Summaries for listing/filtering. |
| `GetSankalpaDetail` | One sankalpa with derived end date and current state. |
| `GetSessions` | Logged sessions for a sankalpa. |
| `GetLifecycleHistory` | Audit history for lifecycle transitions. |
| `GetPeriodOutcomes` | Derived outcomes for period windows. |

`GetPeriodOutcomes` is the only query that needs domain logic. It requires a `from` and `until`
date and selects period windows whose start dates fall in that range. It then loads sessions from
the first selected window's start through the last selected window's end and runs
`PeriodOutcomeCalculator`. This bounds work for long-running commitments without undercounting a
window that crosses a query boundary or introducing stored projections.

## Ports

```java
public interface SankalpaRepository {
    Optional<Sankalpa> findById(SankalpaId id);
    void save(Sankalpa sankalpa);
}

public interface SessionRepository {
    void save(Session session);
    List<Session> findForSankalpa(
        SankalpaId sankalpaId, LocalDate from, LocalDate until);
}

public interface SankalpaReadPort {
    List<SankalpaSummaryRow> list(SankalpaFilter filter);
    Optional<SankalpaDetailRow> detail(SankalpaId id);
    List<SessionRow> sessions(SankalpaId id, LocalDate from, LocalDate until);
    List<LifecycleTransitionRow> lifecycleHistory(SankalpaId id);
}

public interface SankalpaClock {
    LocalDateTime now();
    LocalDate today();
}
```

No `DomainEventPublisher`, command bus, unit-of-work port, or logger port is needed for the current
requirements.

## Use-Case Shape

Example backdated Begin command:

```java
public Result<Void, SankalpaCommandError> handle(BeginSankalpaCommand command) {
    Sankalpa sankalpa = repository.findById(command.sankalpaId())
        .orElse(null);

    if (sankalpa == null) {
        return Result.err(new SankalpaNotFound(command.sankalpaId()));
    }

    LocalDateTime recordedAt = clock.now();
    LocalDateTime effectiveAt = command.effectiveAt().orElse(recordedAt);
    BeginTiming timing = new BeginTiming(effectiveAt, recordedAt);
    Result<Void, LifecycleTransitionError> result = sankalpa.begin(timing);

    if (result instanceof Result.Err<Void, LifecycleTransitionError> err) {
        return Result.err(err.error());
    }

    repository.save(sankalpa);
    return Result.ok(null);
}
```

The use case does not inspect current state; the aggregate handles lifecycle and timing rules.
Only `BeginSankalpa` accepts an optional `effectiveAt`; omitting it means now. `recordedAt` is never
client supplied. Every other lifecycle command supplies `clock.now()` directly to the aggregate.
A session command accepts a past `occurredAt` and checks both commitment coverage and the timeline's
state at that time.

## HTTP Shape

Use intention-revealing endpoints:

| Method | Path | Use case |
|---|---|---|
| `POST` | `/sankalpas` | `DeclareSankalpa` |
| `GET` | `/sankalpas` | `FindSankalpas` |
| `GET` | `/sankalpas/{id}` | `GetSankalpaDetail` |
| `POST` | `/sankalpas/{id}/begin` | `BeginSankalpa` |
| `POST` | `/sankalpas/{id}/pause` | `PauseSankalpa` |
| `POST` | `/sankalpas/{id}/resume` | `ResumeSankalpa` |
| `POST` | `/sankalpas/{id}/complete` | `CompleteSankalpa` |
| `POST` | `/sankalpas/{id}/stop` | `StopSankalpa` |
| `POST` | `/sankalpas/{id}/sessions` | `LogSession` |
| `GET` | `/sankalpas/{id}/sessions` | `GetSessions` |
| `GET` | `/sankalpas/{id}/period-outcomes?from=...&until=...` | `GetPeriodOutcomes` |
| `GET` | `/sankalpas/{id}/lifecycle-history` | `GetLifecycleHistory` |

Do not add `PATCH`, `PUT`, or `DELETE` until changing/deleting sankalpas is in scope.

Only the Begin request body may contain `effectiveAt`. The response/read models expose both
`effectiveAt` and `recordedAt` for each audit entry; they are equal for all other transitions.
