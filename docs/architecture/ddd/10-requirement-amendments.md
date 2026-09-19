# 10 — Possible Requirement Amendments

This file lists optional clarifications to consider before expanding the design. These are not part
of the architecture until they are accepted into
[docs/requirements/sankalpa.md](../../requirements/sankalpa.md).

## A1 — Single User

Add after the examples in `## Purpose` if this is a personal, single-user app:

```markdown
Sankalpa serves a single user.
```

## A2 — Activity Examples Are Not Data

No amendment needed if the current examples are only illustrative.

Add this only if ambiguity keeps recurring:

```markdown
The example activities are illustrative and are not managed as separate data.
```

## A3 — Missed Count

Replace the missed-count sentence if explicit Missed sessions should not double-count:

```markdown
When a period ends, missed sessions are the Number of times less the sessions logged as Performed.
```

Optionally add:

```markdown
A session logged as Missed records that the user did not perform the action on that occasion.
```

## A4 — End Date Boundary

Clarify whether the end date is inclusive.

If inclusive:

```markdown
The end date is the last date on which sessions count.
```

If exclusive:

```markdown
The end date is the first date after the commitment ends.
```

## A5 — Paused Periods

Add only if paused periods should be exempt from ordinary satisfaction/missed calculation:

```markdown
A period in which the sankalpa was paused at any time is reported as Paused.
A Paused period counts as neither satisfied nor missed.
```

Without this clarification, the simpler design should not add a special `PAUSED` period outcome.

## A6 — Backdated Transitions

Add only if a backdated sankalpa can be moved to In progress for a past date:

```markdown
Each lifecycle transition takes effect on a date and time the user gives, defaulting to the current date and time.
A transition cannot take effect in the future.
A transition cannot take effect before the start date.
A transition cannot take effect before the preceding transition.
```

Then replace the audit sentence with:

```markdown
Each lifecycle transition is recorded with the date and time it took effect and the date and time it was recorded.
```

## A7 — Time Zone

Add only if each sankalpa or user needs its own timezone:

```markdown
Each sankalpa has a time zone, which the user sets when declaring it.
When the user does not set one, the system's time zone applies.
All dates and times on a sankalpa are interpreted in its time zone.
```

## A8 — Changing Or Deleting A Sankalpa

Add only if the product needs these operations:

```markdown
While a sankalpa is Not started, the user can change any of its Key Information and can delete the sankalpa.
In every other state, the user can change only the title and description.
```

## A9 — Changing A Session

Add only if this should be explicit:

```markdown
A logged session records a past event and cannot be changed.
```

Or define the edit/delete rules if sessions should be correctable.
