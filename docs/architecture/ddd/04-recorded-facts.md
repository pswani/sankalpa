# 04 — Recorded Facts

The requirements ask for lifecycle transitions to be audit logged and for unresolved client
session operations to be retained. They do not ask for server domain events, event handlers,
integration events, or a server outbox.

So the design records facts directly:

- `LifecycleTimeline` stores lifecycle transitions in order.
- `Session` stores one logged performed session shared through derived contributions.
- Extension metadata records the source and creation time. Copied lifecycle entries retain
  their original vow in `originSankalpaId`. Successful terminal transitions supply achievements.
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
    LocalDateTime recordedAt,
    SankalpaId originSankalpaId,
    List<BeginCorrection> beginCorrections
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

## Extension History and Completion

Extension creation is recorded by `extensionOf` and `declaredAt`, separately from lifecycle
transitions. Inherited entries retain both timestamps and their original origin even after
multiple extensions. Later transitions belong to each vow independently. A successful completion
is acknowledged from the completion command result and remains visible from the vow's terminal
transition. Session correction recalculates counts but never rewrites this user-declared outcome.
No session contribution facts or separate achievement records are stored. See
[Linked extensions](11-linked-extensions.md) for retry and client behavior.

## Explicit initial-Begin correction

The [historical-observance recovery design](../../design/conversational-batch-sessions/history-repair.md)
permits a narrow exception to an unchanged effective timeline. An independent OBSERVANCE with
one initial Begin and no existing correction may propose an earlier effective Begin inside its
commitment. Confirming the version-3 batch writes that correction and all sessions in one transaction.
No interpretation/read operation changes history. Paused, terminal, previously corrected, and linked
vows are excluded. Ordinary repository saves remain append-only.

The initial transition retains its original `recordedAt` and origin. Its immutable `BeginCorrection`
receipt stores a stable UUID, previous effective time, corrected effective time, and approval recording
time. API, native cache, imports, and later extension copies retain that receipt. SQLite adds
`begin_corrections_json` through an idempotent additive migration; Dynamo embeds it in the VOW
document. The 30-entry fenced transaction uses 96 actions including the one corrected VOW.
