# 05 — Application Layer

The application layer coordinates use cases. It should load data, map input into domain values,
invoke domain behavior, save results, and return success or a domain error.

It should not duplicate lifecycle or commitment rules.

## Commands

Commands in current scope:

| Command | Purpose |
|---|---|
| `DeclareSankalpa` | Create a sankalpa in Not started. |
| `BeginSankalpa` | Move a sankalpa to In progress. |
| `PauseSankalpa` | Move a sankalpa to Paused. |
| `ResumeSankalpa` | Move a sankalpa back to In progress. |
| `CompleteSankalpa` | Move a sankalpa to one of the completed states. |
| `StopSankalpa` | Move a sankalpa to Stopped. |
| `LogSession` | Record a past session as Performed or Missed. |

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

`GetPeriodOutcomes` is the only query that needs domain logic. It loads the sankalpa and sessions,
then runs `PeriodOutcomeCalculator`.

## Ports

```java
public interface SankalpaRepository {
    Optional<Sankalpa> findById(SankalpaId id);
    void save(Sankalpa sankalpa);
}

public interface SessionRepository {
    void save(Session session);
    List<Session> findForSankalpa(SankalpaId sankalpaId);
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

Example lifecycle command:

```java
public Result<Void, SankalpaCommandError> handle(BeginSankalpaCommand command) {
    Sankalpa sankalpa = repository.findById(command.sankalpaId())
        .orElse(null);

    if (sankalpa == null) {
        return Result.err(new SankalpaNotFound(command.sankalpaId()));
    }

    Result<Void, TransitionNotAllowed> result = sankalpa.begin(clock.now());

    if (result instanceof Result.Err<Void, TransitionNotAllowed> err) {
        return Result.err(err.error());
    }

    repository.save(sankalpa);
    return Result.ok(null);
}
```

The use case does not inspect current state. The aggregate handles the rule.

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
| `GET` | `/sankalpas/{id}/period-outcomes` | `GetPeriodOutcomes` |
| `GET` | `/sankalpas/{id}/lifecycle-history` | `GetLifecycleHistory` |

Do not add `PATCH`, `PUT`, or `DELETE` until changing/deleting sankalpas is in scope.
