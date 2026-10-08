# Linked Sankalpa Extensions

## Purpose

The user can extend an ongoing sankalpa into a longer, linked vow while preserving the
original vow as a separate commitment. Each vow can be completed and celebrated independently.
Sessions from the same practice contribute to every eligible vow in the linked series.

For example, the user extends a 40-day Vipassana sankalpa to 90 days after practicing for
30 days. Both vows retain the same start date and the first 30 days of sessions. The user
can complete the 40-day vow successfully and continue practicing toward the 90-day vow.

The [Sankalpa requirements](sankalpa.md) apply unless this document states a feature-specific
rule below. Observance sessions follow the same rules as other sessions.

## Linked series

A **linked series** consists of an original sankalpa and the extensions created from it.
An **extension** is a new sankalpa with a longer total duration, linked to its source sankalpa.

- Only the explicit extension action creates this relationship.
- Similar titles, action types, or overlapping dates do not establish a link.
- Each sankalpa can have one direct extension. The user can extend that extension again,
  producing a series of progressively longer vows.
- The user can identify the source and extension of each vow and navigate between them.
- Each vow shows its own duration, end date, progress, and lifecycle state.

## Creating an extension

- The user can extend a finite sankalpa in the In progress or Paused state.
- A sankalpa without a duration cannot be extended.
- The user chooses a new total duration measured from the original start date.
- The new duration must be a whole number of the source sankalpa's periods and greater
  than its total duration.
- The new end date must be on or after the date the extension is created.
- Before creating the extension, the application shows the source duration and end date,
  the proposed duration and end date, and that sessions will be shared.
- Cancelling leaves the source unchanged and creates no extension.
- Creating the extension leaves the source's commitment, lifecycle, and sessions unchanged.
- The extension inherits the source's title, description, action type, start date,
  period, and Number of times per Period.
- The extension retains the original start date even when that date is more than one year
  in the past. The one-year limit continues to apply to newly declared, unrelated sankalpas.
- The extension preserves the source's lifecycle history up to creation, including Begin
  and Paused intervals, so historical session eligibility and period outcomes remain consistent.
- The extension starts in the source's current state: In progress or Paused.
- The application records when the extension was created and which sankalpa it extends.
  Inherited lifecycle history is identified as inherited from the source.

## Sharing sessions

- All existing sessions in the linked series count toward the new extension wherever
  the extension was In progress at the performed time and its date range covers that time.
- A session logged through any vow in the series counts toward every eligible vow in
  that series, including sessions logged after the extension was created for earlier dates.
- The vow through which the user logs the session must itself be eligible at the performed time.
- Eligibility uses the date and time the action was performed, rather than when it was logged.
- Each vow's own date range and lifecycle history determine its eligibility.
- Sharing a session does not change another vow's lifecycle state or end date.
- A session contributes at most once to any vow, including when logging is retried.
- The user can see which vows a session contributes to.
- Each vow's session history and totals include the sessions that contribute to it.
- The journal and totals across multiple vows count each performed session once, even
  when it contributes to several vows.
- The rapid-repeat confirmation rule applies across the linked series. Switching to
  another linked vow does not bypass the one-minute confirmation requirement.
- Confirmed separate sessions remain separate, including when their performed times are identical.

## Correction and deletion

- Undoing or permanently deleting a shared session removes it from every vow it contributes to.
- Before permanent deletion, the application explains that the session will be removed
  from all affected vows.
- Each affected vow's totals and period outcomes are recalculated under the existing
  session-correction rules.
- Pending logging, Undo, deletion, and rejection have a consistent effect across the affected vows.
- A session deleted before an extension is created does not appear in that extension.
- Correcting sessions does not automatically change a user-declared completion outcome.

## Independent completion and celebration

- After creation, Begin, Pause, Resume, Complete, and Stop follow each vow's own lifecycle rules.
- Pausing, resuming, completing, or stopping one vow does not change another vow's state.
- Reaching an end date does not automatically complete a vow.
- The user can mark the original vow Completed - Successfully and continue the extension.
- Each vow marked Completed - Successfully receives its own completion acknowledgement,
  identifying the vow and its duration.
- Completed vows remain visible as separate achievements within the linked series.
- Completing an extension does not automatically mark shorter vows as completed.
- A completed or stopped vow can still receive backfilled shared sessions from times
  when it was In progress, within its date range.
- Sessions performed after a shorter vow's end date contribute only to eligible longer vows.

## Initial scope

This feature covers extending the duration of the same practice. It does not include
changing the activity or frequency, linking unrelated sankalpas, branching or merging
series, unlinking vows, or extending Completed or Stopped vows. Celebration is limited
to acknowledging each successful completion and preserving its achievement; badges,
points, and streaks are outside this feature.
