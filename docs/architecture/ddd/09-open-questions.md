# 09 — Open Questions

These unresolved requirement gaps remain outside the architecture until the product answers them.

## Q1 — What Time Zone Interprets Dates And Times?

The requirements mention date/time but not time zones.

Current design assumption: the application uses one configured system timezone at the boundary.

Do not add `ZoneId` to the domain model until per-sankalpa or per-user time zones are required.

## Q2 — Can A Sankalpa Be Changed Or Deleted?

The requirements do not include editing or deleting a sankalpa.

Do not add `AmendSankalpa`, `ReviseSankalpa`, or `DeleteSankalpa` until those use cases are
requirements.

## Q3 — Can A Logged Session Be Changed Or Deleted?

The requirements do not include editing or deleting logged sessions.

Current design assumption: a session records a past fact and has no update/delete use case.
