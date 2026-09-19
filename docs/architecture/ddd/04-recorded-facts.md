# 04 — Recorded Facts

The requirements ask for lifecycle transitions to be audit logged. They do not ask for domain
events, event handlers, integration events, an outbox, or asynchronous reactions.

So the design records facts directly:

- `LifecycleTimeline` stores lifecycle transitions in order.
- `Session` stores a logged performed or missed session.
- Persistence stores those facts so they can be queried later.

No event dispatcher is part of the current design.

## Lifecycle Audit

```java
public record LifecycleTransition(
    LifecycleState from,
    LifecycleState to,
    LocalDateTime transitionedAt
) {}

public record LifecycleTimeline(
    LifecycleState current,
    List<LifecycleTransition> transitions
) {}
```

The timeline is domain data, not infrastructure. It is needed for two current requirements:

- Audit lifecycle transitions.
- Decide whether a session was logged for a time when the sankalpa was In progress.

## Session History

```java
public final class Session {
    private final SessionId id;
    private final SankalpaId sankalpaId;
    private final LocalDateTime occurredAt;
    private final SessionStatus status;
    private final LocalDateTime loggedAt;
}
```

A session is a recorded past fact. The current requirements do not include editing or deleting
sessions.

## When Events Would Add Value

Add domain or integration events only when there is a real consumer:

| Trigger | Possible event |
|---|---|
| Reminder capability reacts when a sankalpa begins or resumes | `SankalpaBegan`, `SankalpaResumed` |
| External analytics consumes completed/stopped facts | Versioned integration events |
| Period outcomes become too expensive to derive on read | Projection-updating events |

Until then, event infrastructure would be ceremony.
