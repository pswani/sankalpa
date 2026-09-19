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

**Why.** The requirements explicitly ask for transition audit logging. The same history is also
needed to know whether a session was logged while the sankalpa was In progress.

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
per-sankalpa time zones, paused-period exemptions, effective-dated transitions, activity catalogues,
or ownership until the requirements say so.

**Why.** These may become valuable, but adding them now would make the model do work the product has
not asked it to do.
