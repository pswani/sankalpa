# 10 — Possible Requirement Amendments

This file contains only possible future clarifications that are not already stated in
[docs/requirements/sankalpa.md](../../requirements/sankalpa.md). Once an amendment is accepted and
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
