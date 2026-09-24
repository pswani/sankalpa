# 04 — Recorded Facts

The requirements ask for lifecycle transitions to be audit logged and for unresolved client
session operations to be retained. They do not ask for server domain events, event handlers,
integration events, or a server outbox.

So the design records facts directly:

- `LifecycleTimeline` stores lifecycle transitions in order.
- `Session` stores a logged performed session.
- The server's session-identity ledger stores the minimum command fact needed for replay and
  permanent deletion.
- The iOS operation journal stores unresolved client intent until the server decides it.
- Persistence stores those facts so they can be queried later.

Neither reliability store is an event stream, and no event dispatcher is part of the design.

## Lifecycle Audit

```java
public record LifecycleTransition(
    LifecycleState from,
    LifecycleState to,
    LocalDateTime effectiveAt,
    LocalDateTime recordedAt
) {}

public record LifecycleTimeline(
    LifecycleState current,
    List<LifecycleTransition> transitions
) {}
```

The timeline is domain data, not infrastructure. It is needed for three current requirements:

- Audit lifecycle transitions.
- Decide whether a session occurred at a time when the sankalpa was In progress.
- Determine whether an entire period window was Paused.

Only the transition from Not started to In progress may have an `effectiveAt` earlier than its
`recordedAt`. This lets a newly declared sankalpa begin on a past date so past performed sessions
can be logged. Pause, Resume, Complete, and Stop use the clock's current time for both timestamps.
Because no later transition can be backdated, an accepted session's lifecycle eligibility cannot be
rewritten by a later command after that session commits. This statement concerns commands already
ordered in history; the persistence adapter must still give overlapping session and lifecycle
commands one transactional order.

## Session History

```java
public final class Session {
    private final SessionId id;
    private final SankalpaId sankalpaId;
    private final LocalDateTime occurredAt;
    private final LocalDateTime loggedAt;
}
```

A session is a recorded past fact and cannot be edited. Permanent deletion removes that fact from
the active store, so history and derived outcomes are recalculated as though it were never logged.

Deletion must still reserve the identity. The server retains a technical ledger row containing
only session ID, sankalpa ID, and `DELETED`; it does not retain the deleted performed-at or logged-at
fact. This is a resurrection guard, not user-visible audit history.

The client journal is different: it is the durable copy of an unresolved create or delete. Once
the server accepts a command and the accepted state reaches the local cache, its journal operation
is removed. A later refusal is retained as a notice only until the user acknowledges it.

## When Events Would Add Value

Add domain or integration events only when there is a real consumer:

| Trigger | Possible event |
|---|---|
| Reminder capability reacts when a sankalpa begins or resumes | `SankalpaBegan`, `SankalpaResumed` |
| External analytics consumes completed/stopped facts | Versioned integration events |
| Period outcomes become too expensive to derive on read | Projection-updating events |

Until then, event infrastructure would be ceremony.
