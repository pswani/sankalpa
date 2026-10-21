# Historical observance repair — analysis, design, and dry-run review

Date: October 17, 2026. Supersedes the earlier prohibition on offering any Begin correction only
for the narrowly constrained, explicitly approved recovery described here.

## Analysis

The three screenshots in `tmp/IMG_3880.jpg`–`IMG_3882.jpg` show a valid 30-day request still failing
after the user supplied 12:01 AM. Read-only production diagnostics confirmed a September 14
commitment with its initial Begin recorded on October 17. The 32-day commitment ends October 15.
Changing the time cannot make September sessions eligible. The coordinator discarded the domain
reason before returning tool feedback, so the model incorrectly suggested trying another time.
Previous fixtures began in the past and missed this real configuration. Deployment/version checks
were successful; rebuilding the same code cannot fix this semantic mismatch.

## Design

1. Preserve structured tool feedback: message, domain code, failing occurrence, commitment bounds,
   actual Begin, and lifecycle state. The model must explain the actual constraint, not guess.
2. When a user reports daily observance before an accidentally recorded initial Begin, offer one
   proposal that visibly includes both an earlier Begin and the daily records. No history changes
   during interpretation. Confirm commits the correction, all sessions, and result atomically.
3. Automatic *proposal* of this repair is restricted to OBSERVANCE, an independent original vow,
   exactly one initial Begin transition, no prior correction, no linked extension, and an earlier
   Begin within the commitment. Other lifecycle histories receive specific explanations; no pause,
   stop, completion, extension, or inherited timeline is rewritten.
4. Keep the original Begin recording time and append an immutable correction receipt (identity,
   previous effective time, corrected effective time, recording time) to that Begin audit entry.
   Only the effective time changes. A dedicated repository operation permits precisely this change;
   ordinary saves remain append-only. The API/native history displays the correction audit.
5. A new `assistantBeginCorrection:1` capability and request header gate this behavior. Corrected or
   suggested-time batches use LOG_SESSIONS proposal version 3; version-2 batches continue unchanged.
   Old clients cannot confirm a version they cannot explain. Replay, revision, service, and fencing
   checks precede any mutation. Stable IDs survive failure/retry.
6. Daily observance is a day-based report. On the negotiated new path, an omitted time can produce
   a clearly labeled suggested recording time (00:01), reviewed in the same confirmation. It is not
   presented as a known exact performance time. Explicit user times, including 12:01 AM, are retained.
   Other action types still require a supplied time. No date-only domain storage is silently added.
7. Retain the 30-entry transaction bound and finite commitment coverage. October 16–17 cannot be
   logged under a vow ending October 15; the assistant must explain that separately, never extend
   the commitment silently. Existing eligible days are skipped before rejecting a hypothetical
   chosen timestamp on that day; already recorded observance does not require another occurrence.
8. Render assistant Markdown as formatted text so emphasis is not shown as literal asterisks.

## Dry-run → review → fixes

| Dry run | Required result / design fix |
|---|---|
| Sept 14–Oct 13, initial Begin Oct 17, user time 00:01 | Preview Begin Oct 17 → Sept 14 00:01 plus 30 records; one approval; old Begin remains audited. |
| Same report with no time | Suggested recording time clearly shown; no repetitive demand for an exact moment of an all-day observance. |
| Cancel | No correction, sessions, or revision change. |
| Entry 17 fails, commit response lost, or retry | Roll back everything on refusal; resolve uncertain commit by same proposal/confirmation; never duplicate audit or sessions. |
| Vow paused/resumed, completed, already corrected, or linked | Explain exact blocker; do not offer the narrow automatic correction. |
| Old app or missing repair header | No repair proposal/confirmation; ordinary v2 batches still work. |
| Concurrent lifecycle/session/extension write | Stale revision or snapshot conflict prevents committing an obsolete repair. |
| Extend after a completed repair | Inherit corrected effective history and its original audit receipt; later corrections are blocked once linked. |
| DynamoDB 30 records under run fence | Existing 95 actions plus one VOW update = 96; receipt is embedded in VOW; adapter byte/action guards still apply. |
| Restart/cache restore | Correction receipt and pending v3 proposal survive; old data without optional audit fields still loads. |

Review rejected silent date/time changes, unrestricted lifecycle editing, a second independent
commit for the correction, and deleting/recreating the vow. Those would lose identity, violate
approval, or create partial state. Final implementation must reproduce the screenshot conversation
through the real provider using synthetic data, in addition to deterministic adapter/native tests.
No production mutation is authorized or performed by this investigation.

## Implementation review and evidence

The loop found and corrected these defects before acceptance:

- Failure feedback previously collapsed the domain reason into a generic code. The model now
  receives the actual message, Begin timestamp, state, and commitment boundaries as structured JSON.
- The first migration attempt changed the bootstrap table shape, breaking legacy positional
  inserts. The final migration is additive after linked-schema initialization and idempotent on
  an existing database. Legacy rows and old proposal fixtures remain readable.
- Daily satisfaction must precede validation of a hypothetical timestamp. Planning now finds the
  earliest **missing** day before proposing a Begin correction, avoiding an unnecessary correction
  when an earlier same-day contribution already satisfies the date.
- A real-provider follow-up overgeneralized an already-recorded subset to a longer request.
  All-recorded feedback now names `verifiedDates`; the model instructions forbid extrapolating
  completeness or inferring it from totals. A deterministic regression pins that scope.
- Audit decoding checks effective-time equality, the original effective/recorded ordering, one
  correction at most, and the later correction recording time. Native cache round-trip retains it.

Real-provider verification used the configured model against a fresh local SQLite database and
synthetic copy of the screenshot's dates, never the user's real practice. The five-message reproduction using the screenshot's user requests, ending “12:01 AM sounds good” produced version 3 with September 14 00:01 Begin plus
30 entries through October 13. Confirmation persisted 30 sessions and one correction receipt;
confirmation replay left both counts unchanged. A subsequent October 14–15 observance request
without an exact time produced two records with `recordingTimeSuggested=true`.

Deterministic coverage includes cancellation, no mutation before confirmation, old-client refusal,
late domain-failure rollback of correction/audit/sessions/revision, paused/linked exclusions,
finite-coverage refusal, existing-day skipping, inherited audit on extension, SQLite migration and
cold reload, native preview recovery/header negotiation/audit mapping, and a real DynamoDB Local
SDK commit under a run fence. The in-memory adapter asserts 96 distinct actions for the corrected
30-record transaction. Existing transaction-size and byte guards remain active.

The real-provider run is an observed acceptance sample, not a claim that model output is
universally deterministic. Production deployment and physical-device confirmation are separate
from local verification; the investigation has made no production writes.
