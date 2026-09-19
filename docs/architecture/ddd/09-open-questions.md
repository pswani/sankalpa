# 09 — Open Questions

These are requirement gaps. The architecture must not silently answer them by adding concepts that
look like DDD but are not requested by the product.

## Q1 — Is Sankalpa Single-User?

The requirements say "the user" but do not explicitly say whether the system is single-user,
multi-user, or account-based.

Current design assumption: no identity or ownership model.

Add identity only if sankalpas can belong to different users, be shared, or be filtered by account.

## Q2 — Is The Specific Activity Data?

The requirements list Vipassana, Gym, and similar items as examples by action type.

Current design assumption: these stay in title/description and are not modeled as an `Activity` or
`Practice`.

Add an activity catalogue only if activities have their own rules, metadata, or lifecycle.

## Q3 — How Exactly Are Missed Sessions Counted?

The requirements say a session may be logged as Missed and also say each session not logged as
Performed counts as missed when a period ends.

The design should clarify whether an explicit Missed session:

- is only a note that the user missed that occasion, or
- changes the arithmetic.

Until clarified, avoid a second missed-counting mechanism that can double-count.

## Q4 — Is The End Date Inclusive?

The requirements say end date is derived as start date plus duration. They do not say whether that
date is the last date that counts or the first date after the commitment.

This matters for sessions on the boundary date.

## Q5 — What Happens To A Paused Period?

The requirements say sessions can only be logged while In progress and time spent Paused does not
extend the end date.

They do not say whether a period overlapping a paused span is:

- judged normally,
- excused,
- prorated, or
- shown separately as paused.

Do not add a `PAUSED` period outcome until this is a requirement.

## Q6 — Can A Backdated Sankalpa Have Past Sessions Logged?

The start date may be up to one year in the past, but sessions may only be logged while the sankalpa
was In progress.

If a sankalpa is declared today with a start date three months ago, the requirements do not say
whether the user can move it to In progress effective in the past.

Do not add effective-dated lifecycle transitions unless this behavior is required.

## Q7 — What Time Zone Interprets Dates And Times?

The requirements mention date/time but not time zones.

Current design assumption: the application uses one configured system timezone at the boundary.

Do not add `ZoneId` to the domain model until per-sankalpa or per-user time zones are required.

## Q8 — Can A Sankalpa Be Changed Or Deleted?

The requirements do not include editing or deleting a sankalpa.

Do not add `AmendSankalpa`, `ReviseSankalpa`, or `DeleteSankalpa` until those use cases are
requirements.

## Q9 — Can A Logged Session Be Changed Or Deleted?

The requirements do not include editing or deleting logged sessions.

Current design assumption: a session records a past fact and has no update/delete use case.

## Q10 — Are There Reminders, Notifications, Streaks, Or Scores?

No. These are not in the current requirements.

Do not add events, projections, schedulers, notification contexts, streak calculators, or score
models for them.
