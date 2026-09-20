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

**Decision.** Do not implement `DomainEventPublisher`, event handlers, outbox, process manager, or
integration events.

**Why.** The current requirements have no asynchronous reaction and no external consumer. The audit
requirement is satisfied by stored lifecycle history.

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

## DD-11 — Single User Means No Identity Model

**Decision.** Keep identity, account, and ownership concepts out of the current model.

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
special concurrency rule that arbitrary backdating would require.

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
