# iOS app review

Reviewed September 20, 2026, against `docs/requirements/sankalpa.md` and the DDD design documents. This review covers the current working copy, including the untracked `app/` directory.

The app has a strong foundation: the commitment arithmetic and most lifecycle rules are explicit, readable, and tested. The native interface is coherent at standard text sizes. I would address the data-loss risks and the missing logging paths before relying on it for a real practice history.

P1 means fix before everyday use or release. P2 means a concrete correctness or usability issue to address next. Findings below distinguish executed reproductions from source inspection.

## Where each finding now stands

Addressed after the review, on the branch this document sits on. The findings below are left as
written, because they are the record of what was wrong, not a description of the app today.

| # | Finding | Status |
|---|---|---|
| 1 | A failed load can overwrite the user's data with samples | Fixed — a load failure is distinguished from an empty store, preserved, and raised as recovery; the demo seed is opt-in and only ever seeds a genuinely new store |
| 2 | Failed writes are reported as successful | Fixed — persistence failures propagate through the repository and application boundary; covered by core and storage tests |
| 3 | Valid past sessions cannot be entered after pausing or finishing | Fixed — "Log a past session" is in the detail toolbar in every state that ever had eligible time, and the picker is bounded to eligible moments |
| 4 | Beginning earlier today is disabled | Fixed — "Begin at an earlier time…" is offered from the start date onwards |
| 5 | A future-start sankalpa cannot be stopped before it starts | Fixed — the start-date bound applies to entering In progress only |
| 6 | Clearing all data is undone on the next launch | Fixed — a valid empty store is intentional and stays cleared |
| 7 | Old sessions lose their history navigation | Fixed — the session history is reachable whenever anything has ever been logged, and the preview says when it is empty only for the recent window |
| 8 | "Every period" and the summary use inconsistent, undisclosed limits | Fixed — one range for the list and its tally, disclosed in the footer when it actually cuts something off |
| 9 | Accessibility text sizes break the card hierarchy | Fixed — the detail header, list rows, Today cards, the current-period card, the lifecycle actions and the journal rows all switch to vertical layouts at accessibility sizes; the tour now captures the declaration and logging sheets at that size too |
| 10 | Calling Begin on a paused sankalpa permits a backdated Resume | Fixed — `begin()` requires Not started, `resume()` requires Paused |

From the product and usability list: the duration can now be typed as well as stepped; Today
distinguishes an empty account from one whose sankalpas are all finished, and offers a way to the
finished ones; multi-day periods show their date span on Today so an anchored week is not read as
a calendar week; the midnight rollover refreshes the board; seconds survive the time conversion;
and the stale copy about sample data is gone now that a normal launch starts empty. The test
runner's exit status is the tests' own, the tour asserts each destination instead of skipping it,
and landscape is no longer claimed: the app is portrait only, for the same reason it is iPhone
only.

Still open, and deliberately so: editing or deleting an older session (Q3 — undo covers only the
session just logged), and the time-zone questions in 09-open-questions.

## Findings

### 1. P1 — A failed load can overwrite the user's data with samples

**Location:** [FileSankalpaStore.swift](/Users/prashantwani/wrk/sankalpa/app/Sankalpa/Adapters/FileSankalpaStore.swift:89), [AppModel.swift](/Users/prashantwani/wrk/sankalpa/app/Sankalpa/UI/AppModel.swift:33).

`load()` leaves an empty in-memory store when JSON decoding fails or the schema version is newer than supported. `AppModel` interprets that empty state as a new installation and calls `SampleData.seed`, which writes to the same file. The comments promise preservation, but the startup path immediately overwrites the original.

**Verified:** Using temporary files and the actual store/model code, both malformed JSON and a schema-version-2 envelope were overwritten on initialization. The damaged-file case became five sample sankalpas.

**Fix:** Distinguish missing, successfully loaded, and failed-to-load stores. A load failure should preserve the original, block writes to that file, and display a recovery error. Seed only a deliberately selected new/demo store.

### 2. P1 — Failed writes are reported as successful

**Location:** [FileSankalpaStore.swift](/Users/prashantwani/wrk/sankalpa/app/Sankalpa/Adapters/FileSankalpaStore.swift:114).

The store changes its in-memory data, catches file-write errors, and returns normally. The application service and UI then report success. This affects declarations, logged sessions, lifecycle transitions, and clearing data. Atomic file replacement protects an individual write; it does not make a failed write successful.

**Verified:** Pointing the store at a file in a nonexistent parent directory produced a nil command error, the banner “Sankalpa declared,” and one item in memory. Reloading found zero items.

**Fix:** Propagate persistence failures through the repository and application boundary, and show success only after durable storage succeeds. Keep or restore the previous in-memory state when saving fails. Add narrow adapter tests for failed writes and round trips.

### 3. P1 — Valid past sessions cannot be entered after pausing or finishing

**Location:** [SankalpaDetailView.swift](/Users/prashantwani/wrk/sankalpa/app/Sankalpa/UI/Sankalpas/SankalpaDetailView.swift:43), [TodayView.swift](/Users/prashantwani/wrk/sankalpa/app/Sankalpa/UI/Today/TodayView.swift:191).

The requirements judge session eligibility using the state when the session occurred. The core correctly allows an earlier In progress session to be recorded after Stop, and an existing test explicitly verifies this. However, the detail screen exposes logging only inside the current-period card for an In progress sankalpa. Today offers only Resume for paused items and excludes terminal items entirely.

**Reproduction path from source:** Perform a session while In progress, pause or complete the sankalpa, then try to record the forgotten session. There is no logging control. Resuming a paused item just to backfill would unnecessarily change its audit history; a terminal item cannot be resumed.

**Fix:** Put “Log a past session” in a persistent location on detail whenever historical eligible time exists, including Paused and terminal states. Keep timestamp validation in the domain. Update the paused explanation, which currently says nothing can be logged while paused. An In progress commitment whose end date has passed should also retain this action on detail; currently its backfill action survives only on Today.

### 4. P2 — Beginning earlier today is disabled

**Location:** [SankalpaDetailView.swift](/Users/prashantwani/wrk/sankalpa/app/Sankalpa/UI/Sankalpas/SankalpaDetailView.swift:335).

The backdated Begin button is disabled when `startDate >= today`, although its sheet supports both date and time. A user declaring a sankalpa at noon with today's start date cannot begin it at 7 a.m. to record a morning session. Choosing Begin now makes the earlier session permanently ineligible under the current UI.

**Evidence:** Source inspection of the disabled condition, picker, and domain timestamp validation.

**Fix:** Permit any effective timestamp from the start of the commitment through now. Label the action “Begin at an earlier time…” so same-day use is discoverable.

### 5. P2 — A future-start sankalpa cannot be stopped before it starts

**Location:** [LifecycleTimeline.swift](/Users/prashantwani/wrk/sankalpa/app/SankalpaCore/Sources/SankalpaCore/Domain/Lifecycle/LifecycleTimeline.swift:35).

The app deliberately permits future start dates and offers Stop and Complete while Not started. However, the timeline applies the commitment-start lower bound to every transition. Stopping tomorrow's sankalpa today throws `transitionBeforeStart`. The requirements apply this date restriction to Begin and explicitly permit Not started → Stopped.

**Verified:** Declaring an item starting tomorrow and stopping it today was rejected by the actual domain code.

**Fix:** Apply the start-date bound to entering In progress. Permit otherwise legal terminal transitions at the current time before the planned start, with no evaluated periods.

### 6. P2 — Clearing all data is undone on the next launch

**Location:** [AppModel.swift](/Users/prashantwani/wrk/sankalpa/app/Sankalpa/UI/AppModel.swift:33).

The seeding condition tests whether the store is empty, not whether it has ever been initialized. Clear everything writes a valid empty store; reopening the app fills it with examples again.

**Verified:** Clear followed by constructing a new model against the same file restored five samples.

**Fix:** Treat a valid empty file as intentional. Prefer an explicit demo mode or a one-time initialization marker. Sample data currently ships through the normal startup path in both Debug and Release, so it should be clearly separated from the user's history.

### 7. P2 — Old sessions lose their history navigation

**Location:** [SankalpaDetailView.swift](/Users/prashantwani/wrk/sankalpa/app/Sankalpa/UI/Sankalpas/SankalpaDetailView.swift:258).

The detail section queries only the last 120 days and renders “All sessions” only when that query is nonempty. For a completed practice whose latest session was 150 days ago, the app says “No sessions logged yet” and removes access to the full history, even though the lifetime count is positive. The cross-sankalpa Journal still provides a partial workaround until its own 365-day window expires.

**Verified:** A temporary store with one session 150 days old reported one lifetime session and zero recent sessions. The corresponding UI branch hides history navigation.

**Fix:** Always offer history when the lifetime count is positive; use “No sessions in the last 120 days” for the recent preview. Provide a date range or pagination for older records.

### 8. P2 — “Every period” and the summary use inconsistent, undisclosed limits

**Location:** [HistoryViews.swift](/Users/prashantwani/wrk/sankalpa/app/Sankalpa/UI/Sankalpas/HistoryViews.swift:10), [SankalpaApplicationService+Queries.swift](/Users/prashantwani/wrk/sankalpa/app/SankalpaCore/Sources/SankalpaCore/Application/Queries/SankalpaApplicationService+Queries.swift:120).

The period list shows at most 400 windows, while its tally uses at most 520. Neither identifies a limited reporting range or provides access to older periods. The Journal similarly stops at 365 days. Bounded reads are a sound design choice, but invisible retention-like limits misrepresent the available history.

**Verified:** For an ongoing daily commitment with 600 closed periods, the model returned a tally of 519 evaluated periods and 400 “Every period” rows. The current open period occupies one slot, explaining why the evaluated count is below 520.

**Fix:** Use one explicit range for the list and its tally, and add paging or a range selector. Keep bounded queries; make older data reachable and the scope visible.

### 9. P2 — Accessibility text sizes break the card hierarchy

**Location:** [SankalpaDetailView.swift](/Users/prashantwani/wrk/sankalpa/app/Sankalpa/UI/Sankalpas/SankalpaDetailView.swift:62), [SankalpaListView.swift](/Users/prashantwani/wrk/sankalpa/app/Sankalpa/UI/Sankalpas/SankalpaListView.swift:181).

The title, icon, and state badge remain side by side at large accessibility sizes. The screenshots show “Vipassana” split across lines and “In progress” broken into narrow fragments inside a tall capsule. This is especially difficult to read in the list, where the badge competes with period progress.

**Evidence:** Visual inspection of the accessibility-size detail and list screenshots. The screen test captures these layouts but does not assert readability.

**Fix:** Switch these rows to vertical layouts at accessibility sizes or use an adaptive layout. Let titles and state labels retain natural word wrapping. Inspect the declaration and logging sheets at the largest sizes as well; the current large-text tour covers only Today, detail, and the list.

### 10. P2 — Calling Begin on a paused sankalpa permits a backdated Resume

**Location:** [Sankalpa.swift](/Users/prashantwani/wrk/sankalpa/app/SankalpaCore/Sources/SankalpaCore/Domain/Sankalpa.swift:102).

`begin()` simply requests an In progress transition. Since Paused → In progress is legal, it accepts a backdated Begin from Paused too. Only the initial Not started → In progress transition may be backdated. The current UI uses the correct Resume command, so this defect is in the public domain/application API rather than an exposed button.

**Verified:** Begin at 7 a.m., Pause at 8 a.m., then call Begin at noon with an effective time of 9 a.m. The operation succeeds and rewrites the paused interval's end into the past.

**Fix:** Require Not started in `begin()`, Paused in `resume()`, and enforce that distinct effective/recorded times are allowed only for the initial Begin. Test the use-case methods, not just the transition table.

## What is working well

- Commitment windows are independently anchored to the original start date. Tests cover January 31 and leap-day cases, inclusive end dates, and whole-period duration.
- Number of times is correctly treated as a minimum. Extra sessions satisfy the period without producing negative missed counts.
- Pause intervals preserve the original schedule; partial pauses keep the full requirement, and entirely paused periods are exempt.
- Reaching an end date does not silently complete the sankalpa. Terminal transitions exclude interrupted periods.
- Effective and recorded lifecycle timestamps are retained, and outcomes are derived instead of persisted as a competing source of truth.
- The domain/application package has a useful separation from SwiftUI and storage. One application service and a simple local store are reasonable choices for this single-user scope; a server or more architectural layers are unnecessary.
- Standard-size screens have consistent cards, spacing, action colors, and clear Today/Sankalpas/Journal navigation. State labels use words and symbols, not color alone. The dark palette is coherent.

## Product and usability improvements

These are improvements or decisions, not additional claimed requirement violations.

- **Make longer durations easy to enter.** Going from the default 30 days to 180 requires 150 stepper increments unless the user holds the control. A numeric field alongside the stepper would make common commitments easier to enter.
- **Make anchored periods clear on Today.** “This week” can suggest a calendar week, while this app's week begins on the commitment start date. Show the current date span or “current 7-day period” where ambiguity matters.
- **Distinguish empty Today from an empty account.** When all sankalpas are finished, Today currently says “No sankalpas yet.” “No active sankalpas” with a route to finished items would be accurate.
- **Decide how mistakes are corrected.** One-tap logging is convenient, but a double tap records two sessions and no correction action exists. Edit/delete is explicitly unresolved in the requirements, so its absence is not a defect against current scope. Resolve that product decision before everyday use; an undo flow needs an agreed rule for correcting recorded facts.
- **Resolve the documented interpretations.** Confirm whether pre-Begin closed periods should count as missed, and whether future start dates are intended. Also label 180 days as 180 days: it is not always six calendar months.
- **Keep time conversion precise.** `AppTime.date(from:)` omits seconds; a verified round trip changed 12:34:56 to 12:34:00. This can matter immediately after Begin/Resume when the picker rounds backward into an ineligible interval. Preserve seconds internally and make the minute-resolution UI behavior deliberate.
- **Clarify timezone and clock-change behavior.** The boundary uses an auto-updating device timezone despite its comment saying it is read once. The project already lists timezone semantics as an open question. Define expected behavior for travel and daylight-saving clock changes before adding more time modeling.
- **Refresh through midnight.** Today refreshes on foregrounding and successful commands, not simply when an already-open app crosses midnight. A calendar-day change refresh would keep the visible period accurate without requiring another action.

## Test feedback and verification

- The existing core suite ran successfully: **61 tests across 6 suites**.
- A fresh simulator build succeeded, and **all 4 UI smoke tests passed**, with 21 screenshot attachments, on an isolated iPhone 17 Pro simulator using the installed iOS 27 runtime. The temporary simulator was removed after the review.
- Focused executable reproductions compiled the actual persistence/model adapter files with the actual core package, using temporary data. They verified the overwrite, false-success, reseeding, future-stop, backdated-resume, history-limit, and seconds-conversion findings.
- App source files were not changed. Existing simulator data was not cleared or reused for the test run.

The UI tests are useful navigation/screenshot smoke tests, but they are not yet end-to-end behavior coverage. Several destinations use `if element.waitForExistence(...)` and silently skip the check if the screen entry is absent. Declaration is cancelled, and the tour does not verify saved sessions, lifecycle changes, relaunch persistence, or storage failures.

[screen-tour.sh](/Users/prashantwani/wrk/sankalpa/app/scripts/screen-tour.sh:56) also ends the test pipeline with `|| true`, which masks `xcodebuild` failure when attachment export still succeeds. Preserve the test runner's exit status and assert expected destinations. The UI test build emitted actor-isolation warnings in `ScreenTour.swift`; align UI automation with the main actor.

The highest-value additional checks are: failed load preserves bytes; failed save cannot show success; clear/relaunch stays empty; backfill works from Paused and all terminal states; Begin earlier today; Stop before a future start; old history remains reachable; consistent report ranges; and persistence after relaunch. Physical-device behavior, VoiceOver interaction, iPad/landscape layouts, and an iOS 18 runtime were not verified in this review.

Fresh screenshot evidence: [Today](/Users/prashantwani/wrk/sankalpa/docs/reviews/ios-review-screens/01-today.png), [dark detail](/Users/prashantwani/wrk/sankalpa/docs/reviews/ios-review-screens/17-detail-dark.png), [accessibility-size detail](/Users/prashantwani/wrk/sankalpa/docs/reviews/ios-review-screens/20-detail-large-text.png), and [accessibility-size list](/Users/prashantwani/wrk/sankalpa/docs/reviews/ios-review-screens/21-list-large-text.png).

## Recommended order

1. Fix failed-load and failed-save handling, then sample initialization.
2. Restore all valid historical logging paths and same-day Begin; fix future Stop and the Begin/Resume API distinction.
3. Make history complete and its reporting ranges explicit.
4. Adapt layouts for accessibility sizes and strengthen behavioral UI tests.
