# 05 — Application Layer

The application layer coordinates use cases. It should load data, map input into domain values,
invoke domain behavior, save results, and return success or a domain error.

It should not duplicate lifecycle or commitment rules.

## Commands

Commands in current scope:

| Command | Purpose |
|---|---|
| `DeclareSankalpa` | Create a sankalpa in Not started. |
| `ExtendSankalpa` | Create or replay a longer linked vow, preserving the source and inherited history. |
| `BeginSankalpa` | Move a sankalpa to In progress, optionally effective in the past. |
| `PauseSankalpa` | Move a sankalpa to Paused now. |
| `ResumeSankalpa` | Move a sankalpa back to In progress now. |
| `CompleteSankalpa` | Move a sankalpa to one of the completed states now. |
| `StopSankalpa` | Move a sankalpa to Stopped now. |
| `LogSession` | Record or replay one identified past performed session. |
| `DeleteSession` | Permanently remove or preempt one identified session. |

Not in current scope:

- `AmendSankalpa`
- `ReviseSankalpa`
- `DeleteSankalpa`
- session edit use cases

Those should be added only when the requirements add them. Session deletion is in scope; sankalpa
deletion is not.

## Queries

Queries return data and change nothing:

| Query | Returns |
|---|---|
| `FindSankalpas` | Summaries for listing/filtering. |
| `GetSankalpaDetail` | One sankalpa with derived end date and current state. |
| `GetSessions` | Eligible contributing sessions for a vow, with logging owner and contributing vow IDs. |
| `GetJournal` | Range-bounded unique session facts across vows. |
| `GetLinkedSeries` | Source/child navigation, own progress, and separate successful vows. |
| `GetLifecycleHistory` | Audit history for lifecycle transitions. |
| `GetPeriodOutcomes` | Derived outcomes for period windows. |

Contribution queries and counts use the domain performed-time eligibility predicate.
`GetPeriodOutcomes` additionally needs period-calculation logic. It requires a `from` and `until`
date and selects period windows whose start dates fall in that range. It then loads sessions from
the first selected window's start through the last selected window's end and runs
`PeriodOutcomeCalculator`. This bounds work for long-running commitments without undercounting a
window that crosses a query boundary or introducing stored projections.

## Ports

```java
public interface SankalpaRepository {
    Optional<Sankalpa> findById(SankalpaId id);
    Optional<Sankalpa> findByIdForUpdate(SankalpaId id);
    void save(Sankalpa sankalpa);
    Optional<Sankalpa> findDirectExtension(SankalpaId sourceId);
    List<Sankalpa> findSeriesMembers(SankalpaId seriesId);
    void acquireSeriesWriteGuard(SankalpaId seriesId);
}

public interface SessionRepository {
    Optional<SessionIdentity> findIdentity(SessionId sessionId);
    void claimIdentity(SessionId sessionId, SankalpaId sankalpaId, SessionIdentityState state);
    void markDeleted(SessionId sessionId);
    Optional<Session> findById(SessionId sessionId);
    void save(Session session);
    void delete(SessionId sessionId);
    List<Session> findSeriesCandidates(
        SankalpaId seriesId, LocalDate from, LocalDate until);
    // Journal reads page unique active facts; contribution pagination is applied after filtering.
}

public interface SankalpaReadPort {
    List<SankalpaSummaryRow> list(SankalpaFilter filter);
    Optional<SankalpaDetailRow> detail(SankalpaId id);
    // Session rows are assembled from candidates through the shared contribution helper.
    List<SessionRow> journal(LocalDate from, LocalDate until, PageRequest page);
    List<SankalpaDetailRow> linkedSeries(SankalpaId seriesId);
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
    // Entire command runs in the adapter-managed transaction.
    Sankalpa located = repository.findById(command.sankalpaId()).orElse(null);
    if (located == null) {
        return Result.err(new SankalpaNotFound(command.sankalpaId()));
    }
    repository.acquireSeriesWriteGuard(located.seriesId());
    Sankalpa sankalpa = repository.findByIdForUpdate(command.sankalpaId()).orElseThrow();
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
A new session command accepts a stable `SessionId` and past `occurredAt`, then checks both
commitment coverage and the timeline's state at that time. An exact replay returns the existing
session before eligibility is re-evaluated. `DeleteSession` does not apply lifecycle or commitment
eligibility: correction is allowed for every logged session, including one in a closed period.

The application service owns these identity decisions because they coordinate aggregate rules with
repository state:

- absent identity: validate and create;
- active exact identity: replay;
- reused identity with different values/owner: conflict;
- deleted same-owner identity: report permanently deleted;
- delete absent identity: reserve it as deleted;
- delete active same-owner identity: physically remove and reserve it as deleted;
- repeated delete: succeed.

The identity claim, session write/removal, and ledger transition share one transaction. See the
[cross-system design](../../design/session-reliability/README.md) for the complete race tables.
Repository lookup and command-identity failures such as `SankalpaNotFound`,
`SessionIdentityConflict`, and `SessionDeleted` are application errors, not aggregate domain
errors. They likewise remain independent of HTTP status codes.

## HTTP Shape

Use intention-revealing endpoints:

| Method | Path | Use case |
|---|---|---|
| `POST` | `/sankalpas` | `DeclareSankalpa` |
| `POST` | `/sankalpas/{id}/extensions` | `ExtendSankalpa` |
| `GET` | `/sankalpas` | `FindSankalpas` |
| `GET` | `/sankalpas/{id}` | `GetSankalpaDetail` |
| `GET` | `/sankalpas/{id}/linked-series` | `GetLinkedSeries` |
| `GET` | `/sessions?from=...&until=...` | `GetJournal` with cursor pagination |
| `POST` | `/sankalpas/{id}/begin` | `BeginSankalpa` |
| `POST` | `/sankalpas/{id}/pause` | `PauseSankalpa` |
| `POST` | `/sankalpas/{id}/resume` | `ResumeSankalpa` |
| `POST` | `/sankalpas/{id}/complete` | `CompleteSankalpa` |
| `POST` | `/sankalpas/{id}/stop` | `StopSankalpa` |
| `POST` | `/sankalpas/{id}/sessions` | `LogSession` |
| `DELETE` | `/sankalpas/{id}/sessions/{sessionId}` | `DeleteSession` |
| `GET` | `/sankalpas/{id}/sessions` | `GetSessions` |
| `GET` | `/sankalpas/{id}/period-outcomes?from=...&until=...` | `GetPeriodOutcomes` |
| `GET` | `/sankalpas/{id}/lifecycle-history` | `GetLifecycleHistory` |
| `GET` | `/capabilities` | Advertise supported cross-version command contracts |

Do not add `PATCH` or `PUT` for sessions: a performed fact is either present or permanently
deleted. Beyond declaration, explicit extension creation, and lifecycle actions, do not add general
sankalpa mutation/deletion endpoints until those requirements are in scope.

Supported clients send the same UUID in `LogSessionRequest.id` and `Idempotency-Key`; a mismatch is
invalid. First acceptance returns `201`; exact replay returns `200`; both bodies contain the
identified session. Identity conflict returns `409`, and a create preempted by deletion returns
`410`. DELETE is idempotent and returns `204` for both first and repeated success. The temporary
legacy no-ID path and its removal are defined in the cross-system rollout design.
The capability returns `sessionCommandIdentity: 1`, `linkedSankalpaExtensions: 1`, and the
persistent `serviceInstanceId` of the logical data store. The client requires both before sending these commands, so it cannot unknowingly
use the unsafe legacy behavior of an older server. Every identified POST/DELETE also carries that
expected instance ID; the server rejects a mismatch before changing data, so address reuse cannot
retarget pending work to another service.

Only the Begin request body may contain `effectiveAt`. The response/read models expose
`effectiveAt`, `recordedAt`, and `originSankalpaId` for each audit entry. Except for Begin, the
timestamps are equal; inherited entries retain their original timestamps and origin.

## Linked-Series Coordination

[Linked extensions](11-linked-extensions.md) specifies extension identity/replay, root write
ordering, candidate reads, owner-routed deletion, and the versioned linked-series contract.
Session identity decisions still compare the original logging owner. Per-vow histories, counts,
and outcomes use one contribution helper; combined totals use a union of session IDs. Clients
route deletion from any contributing view to the immutable logging owner exposed on each row.
The extension factory supplies creation rules; the application checks existing children and
commits creation with inherited history. No command fans out session writes.
