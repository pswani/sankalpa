# 07 — Design Decisions

Each decision is kept only if it reduces ambiguity, enforces a requirement, or prevents avoidable
complexity.

---

## DD-1 — One Bounded Context

**Decision.** Use one bounded context: `Sankalpa`.

**Why.** The requirements have one language and one workflow. `Commitment`, `Session`, lifecycle,
and period outcomes are tightly related. Splitting them would add translation without adding
independence.

**Removed.** Separate subdomains and prospective context-map relationships.

---

## DD-2 — Model Focus Areas, Not Subdomains

**Decision.** Talk about commitment, lifecycle, session logging, and period outcomes as focus areas
inside the model, not subdomains.

**Why.** They help explain where the complexity is, but they are not autonomous business
capabilities.

**Cost avoided.** No fake package boundaries, ACLs, or future-service language.

---

## DD-3 — Commitment Is A Value Object

**Decision.** Represent start date, period unit, number of times, and optional period count as one
`Commitment`.

**Why.** Period windows and end date are derived from those values together. Keeping them together
makes "whole number of periods" structural instead of a scattered validation rule.

---

## DD-4 — Lifecycle Timeline Is The Audit Log

**Decision.** Store lifecycle transitions inside `LifecycleTimeline`.

**Why.** The requirements explicitly ask for transition audit logging and allow Begin to be
backdated. Each entry therefore stores `effectiveAt`, which drives domain behavior, and
`recordedAt`, which preserves the audit fact. The same history is needed to know whether a session
occurred while the sankalpa was In progress and whether an entire period window was Paused.

**Removed.** Domain events for lifecycle transitions. There is no consumer today.

---

## DD-5 — Session Is Separate From Sankalpa

**Decision.** Keep `Session` separate from the `Sankalpa` aggregate, referenced by `SankalpaId`.

**Why.** Sessions can grow without limit, and no current invariant requires all sessions to be
loaded to log one more. `Sankalpa` still decides whether logging is allowed because it owns the
commitment and lifecycle.

---

## DD-6 — Period Outcomes Are Derived

**Decision.** Do not store period outcomes.

**Why.** A period outcome is derived from commitment, lifecycle, and sessions. Storing it would
create a second truth that can drift.

**Removed.** Projection tables and projection-updating event handlers.

---

## DD-7 — Use Methods Instead Of Specification Objects For Simple Rules

**Decision.** Do not introduce `PeriodSatisfied` or `SankalpaDeletable` specification objects.

**Why.** The current rules are small and have one caller. A named method or helper is clearer than a
pattern object.

Examples:

```java
boolean isSatisfied = performedCount >= commitment.timesPerPeriod().value();
boolean canLog = lifecycle.wasInProgressAt(occurredAt);
```

---

## DD-8 — No Event Infrastructure Yet

**Decision.** Do not implement server `DomainEventPublisher`, event handlers, event outbox, process
manager, or integration events. The iOS operation journal is permitted because it is the durable
copy of unresolved user commands, not event publication infrastructure.

**Why.** No server domain fact has an asynchronous consumer. Client retry is direct command
delivery from its durable journal, not publication of domain events. The audit requirement remains
satisfied by stored lifecycle history.

**Trigger to revisit.** Add events when another feature actually consumes facts from this context.

---

## DD-9 — Ports Only Around Real Boundaries

**Decision.** Keep ports for persistence, read queries, and time. Do not add ports for logging,
domain events, unit of work, or framework abstractions.

**Why.** Persistence and time affect testability and dependencies. Logger and unit-of-work ports
would wrap abstractions already provided by the platform.

---

## DD-10 — Requirement Gaps Stay Open

**Decision.** Do not design in behavior for editing/deleting sankalpas, editing sessions,
per-sankalpa time zones, activity catalogues, or ownership until the requirements say so.

**Why.** These may become valuable, but adding them now would make the model do work the product has
not asked it to do.

---

## DD-11 — Single User Means No User Identity Model

**Decision.** Keep user identity, account, and ownership concepts out of the current model.

**Why.** The application is explicitly single-user. A singleton `User` or owner key would add no
domain rule or isolation boundary.

**Trigger to revisit.** Introduce identity when the application becomes multi-user, shared, or
account-filtered.

---

## DD-12 — End Dates And Period Windows Are Inclusive

**Decision.** A finite commitment's end date is the final covered date. Compute it as the start of
the period after the last window minus one day. Derive every month/year boundary independently from
the original start date plus its period index, using the last valid day when necessary.

**Why.** This makes the boundary rule explicit and gives `endDate()`, `covers(...)`, and session
eligibility one consistent interpretation. Independent anchoring prevents a January 31 commitment
from drifting permanently to the 28th after February and lets a February 29 yearly commitment
return to February 29 in leap years.

---

## DD-13 — Missed Is A Derived Shortfall

**Decision.** For a closed period, `missed = max(0, required - performed)`.

**Why.** Only performed sessions are logged. Missed is the derived shortfall against the minimum,
not a second kind of session record.

---

## DD-14 — Pause Does Not Shift Or Prorate Periods

**Decision.** Pause is a lifecycle interval from Pause until Resume or a terminal transition. It
does not shift period boundaries or reduce the required number of sessions. A partially paused
period is evaluated normally after it closes. Only a period paused for its entire window is reported
as `PAUSED`, with no missed shortfall.

**Why.** Tracking continues in the same period when the user resumes. Limiting the special standing
to fully paused windows avoids letting a brief pause exempt an entire week, month, or year.

---

## DD-15 — Only Begin May Be Backdated

**Decision.** Begin may use a past `effectiveAt`, but it cannot be in the future or before the
commitment start. Pause, Resume, Complete, and Stop take effect at the clock's current time. The
system clock supplies an immutable `recordedAt` for every transition.

**Why.** This supports a past start and later session logging without allowing subsequent commands
to rewrite history. It removes the latest-session lookup, cross-aggregate transition policy, and
historical-rewrite protocol that arbitrary backdating would require. Ordinary transaction isolation
still gives lifecycle and session commands that overlap in execution one commit order.

---

## DD-16 — Commitment Coverage Does Not Drive Lifecycle

**Decision.** Reaching a finite end date does not automatically complete a sankalpa. Commitment
coverage determines which session timestamps count; lifecycle remains user-controlled.

When the user completes or stops, only complete period windows ending before that terminal
transition are evaluated. The interrupted window and later windows are omitted.

**Why.** Automatic completion would contradict the requirement that the user chooses the terminal
state and outcome. Omitting partial windows avoids silently prorating or judging a commitment the
user ended partway through.

---

## DD-17 — Period Outcome Queries Are Range-Bounded

**Decision.** `GetPeriodOutcomes` requires `from` and `until` dates and selects windows whose start
dates fall in that range. It expands the session query to the selected windows' actual boundaries
before calculating outcomes.

**Why.** An indefinite daily commitment can accumulate thousands of windows. A bounded query keeps
work proportional to what the caller is displaying and avoids premature projection infrastructure.

---

## DD-18 — Session Identity Is The Retry Identity

**Decision.** The client creates one `SessionId` for each confirmed logging action and every retry
uses it as the idempotency key. The server preserves it as the session ID.

**Why.** A server-generated identity cannot connect an uncertain request to its retry. Reusing
performed-at as identity would merge legitimate same-time sessions.

---

## DD-19 — One Global Identity Ledger Orders Create And Delete

**Decision.** Every session ID has one durable `ACTIVE` or `DELETED` row in a global identity
ledger. Both create and delete claim that row within their write transaction.

**Why.** Separate active and tombstone tables cannot prevent a cross-parent create/delete race from
committing contradictory rows. One primary key gives all commands a common contention point.

---

## DD-20 — Deletion Removes The Fact But Retains Its Identity Guard

**Decision.** Permanently delete the `Session` fact and retain only ID, owner, and `DELETED` state.

**Why.** Active reads and derived outcomes then have one simple source, while the minimal identity
guard prevents delayed creation. This is not soft deletion or a user-visible audit trail.

---

## DD-21 — Pending Client Operations Are Durable Overlays

**Decision.** Persist unresolved create/delete operations before acknowledging them and overlay
them on the last server snapshot. Bind them to their originating persistent service instance, not
to a network address.

**Why.** A memory-only operation is lost on relaunch; mutating the base snapshot directly makes
rejection hard to reverse; retargeting an operation can corrupt another server.

---

## DD-22 — Server-Accepted State Reaches Cache Before Journal Removal

**Decision.** Apply an accepted create/delete to the durable base snapshot before removing its
pending operation.

**Why.** The reverse order creates a crash window in which a confirmed create disappears or a
confirmed deletion reappears. Leaving the operation briefly is safe because server commands are
idempotent.

---

## DD-23 — Repeat Confirmation Is An Interaction Rule

**Decision.** The client asks for confirmation when another action for the same sankalpa begins
within 60 seconds of an accepted or durably pending log. Confirmation creates a fresh identity.

**Why.** The rule prevents accidental duplicate taps without making time proximity a domain
uniqueness rule. The server accepts intentional same-time sessions.

---

## DD-24 — The Client Negotiates Identity Support Before Writing

**Decision.** The server advertises a versioned session-command-identity capability and a stable
service instance ID stored with its data. The client sends identified creates/deletes only after
that exact instance has advertised support, and every mutation names the expected instance for the
server to validate before changing data.

**Why.** An older server silently ignores the new identity and generates another one. Deployment
instructions alone cannot prevent a new client from connecting to it and duplicating a timed-out
request; capability negotiation plus per-command instance binding can.

---

## DD-25 — Journal Ambiguity Fails Closed

**Decision.** Conflicting same-ID journal operations or legacy operations without a confirmed
service instance block session mutation and delivery while preserving the original data. Recovery
requires an explicit warned discard. Legacy entries are never matched by time or value because
their destination and command identity cannot be established safely.

**Why.** Guessing between create and delete can lose a legitimate session; silently starting over
can lose an unresolved action; inferring a legacy destination can mutate the wrong service; and
time equality alone cannot distinguish a lost response from an intentional same-time session.

---

## DD-26 — Async Results Are Applied Conditionally

**Decision.** Every pending operation has an immutable revision. A response removes or rejects an
operation only when that exact revision is still current. A refresh publishes only for its captured
service binding and refresh-publication revision; starting a newer refresh or accepting a local
session mutation invalidates the older publication.

**Why.** Swift actors are reentrant across network awaits. Undo or service relocation can happen
before an older response returns; unconditional completion would erase the newer decision or
publish data from the wrong service.
