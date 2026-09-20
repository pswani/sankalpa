# 01 — Strategic Design

## One Domain, One Bounded Context

Sankalpa is a small domain. It has meaningful rules, but it does not currently have separate
subdomains.

The whole model belongs to one bounded context: **`Sankalpa`**.

The requirements use one language throughout: sankalpa, commitment, period, session, lifecycle,
paused, completed, stopped. There is no second team, external system, or alternate vocabulary that
requires translation. Splitting this into `Commitment`, `Logging`, `Adherence`, or `Reporting`
contexts would create boundaries that translate the same language back into itself.

## Model Focus Areas

These are not subdomains. They are just the parts of the model that deserve attention.

| Focus area | Why it matters | Design response |
|---|---|---|
| Commitment | Turns "x times per y period for z duration" into concrete period windows. | Model as a value object with derived windows and end date. |
| Lifecycle | Controls when a sankalpa can be acted on and supplies audit history. | Model as explicit states and a transition timeline. |
| Session logging | Records performed sessions and must respect commitment coverage and lifecycle. | Let `Sankalpa` decide whether a session may be logged. |
| Period outcomes | Determines whether closed periods were satisfied. | Derive on read from commitment and sessions. |

Calling these subdomains would imply more independence than they have. They change together and use
the same concepts.

## What Is Not Modeled

The requirements do not ask for these concepts, so the architecture does not include them:

- Identity, accounts, ownership, sharing, coaching, or teams. The application is explicitly
  single-user.
- Activity catalogues for Vipassana, Gym, Sudarshan Kriya, and similar examples.
- Reminders, notifications, nudges, streaks, scoring, or recommendations.
- Separate reporting, analytics, or projection contexts.
- Domain events or integration events.

## When To Revisit

Introduce a new context only when the language actually splits. Good triggers:

- A move beyond the current single-user scope makes ownership and membership real.
- Activities become first-class data with their own lifecycle and rules.
- Reminders or recommendations develop vocabulary beyond simple session tracking.
- Reporting/analytics needs independently maintained projections or external consumers.
- Two parts of the codebase need the same word to mean different things.

Until one of those happens, a single context with ordinary package boundaries is the simpler and
more honest design.
