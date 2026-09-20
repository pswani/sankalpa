# 04 — Recorded Facts

The requirements ask for lifecycle transitions to be audit logged. They do not ask for domain
events, event handlers, integration events, an outbox, or asynchronous reactions.

So the design records facts directly:

- `LifecycleTimeline` stores lifecycle transitions in order.
- `Session` stores a logged performed session.
- Persistence stores those facts so they can be queried later.

No event dispatcher is part of the current design.

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
