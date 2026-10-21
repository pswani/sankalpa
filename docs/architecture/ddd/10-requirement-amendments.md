# 10 — Possible Requirement Amendments

This file contains only possible future clarifications that are not already stated in
[Sankalpa](../../requirements/sankalpa.md) or
[Linked Sankalpa Extensions](../../requirements/linked-sankalpa-extensions.md). Once an amendment is accepted and
added to the requirements, remove it from this file.

## A1 — Activity Examples Are Not Data

**Status:** Deferred; activity data is the next planned evolution, not current scope.

No amendment needed if the current examples are only illustrative.

Add this only if ambiguity keeps recurring:

```markdown
The example activities are illustrative and are not managed as separate data.
```

## A2 — Time Zone

Add only if each sankalpa or user needs its own timezone:

```markdown
Each sankalpa has a time zone, which the user sets when declaring it.
When the user does not set one, the system's time zone applies.
All dates and times on a sankalpa are interpreted in its time zone.
```

## A3 — Changing Or Deleting A Sankalpa

Add only if the product needs these operations:

```markdown
While a sankalpa is Not started, the user can change any of its Key Information and can delete the sankalpa.
In every other state, the user can change only the title and description.
```

## October 17, 2026 — Natural recovery of historical observance

A report of daily observance can precede an accidentally recorded initial Begin. The assistant
must explain this actual conflict and offer the constrained, confirmed repair defined in
[historical observance repair](../../design/conversational-batch-sessions/history-repair.md).
This is an explicit amendment to immutable effective lifecycle history for one initial Begin
of an independent, uncorrected observance. The original effective time remains in an immutable
receipt; later lifecycle transitions and linked timelines cannot be edited by this feature.
The corrected Begin and session batch commit together. No interpretation step mutates practice.

When no performance time exists for a day-based observance report, a new-capability client can
review a labeled 00:01 recording convention. Other activities retain exact supplied times.
Commitment coverage, 30-entry limits, and explicit confirmation remain enforced.
