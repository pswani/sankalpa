# Connected iOS implementation review

Scope: the backend-connected iOS app in `app/`. The independent file-backed app in `app2/` remains separate implementation work.

## Implemented behavior

- Extend an ongoing finite vow using a greater total duration from its original start, with current/new end previews. Keep the original declaration, lifecycle, and completion independent.
- Preserve immutable series/source links and inherited transition provenance. Navigate between identical titles by duration/end date and show each successfully completed vow as a win.
- Read unique canonical session facts with service/version headers and one pinned practice revision. Validate the complete collection before publishing; restart once on revision conflict and retain the previous view on failure.
- Project pending session creation and owner-routed deletion across eligible series members. Keep the global journal unique and the 60-second repeat guard shared across the series.
- Persist one extension attempt before sending. Replay its exact identity/input after timeout or relaunch; retain accepted data until cache application succeeds. Open a competing child with its authoritative duration and a notice, and preserve malformed successes for recovery.
- Apply the same series processing gate, recent-log guard, headers, and contribution explanation to existing assistant session confirmation. No extension conversation tool was added.
- Upgrade old cache/journal readers and preserve the original journal bytes before migration. Surface submitted extensions in Pending Changes without discarding uncertain attempts.

## Implement → test → fix → review → fix

| Finding | Fix and evidence |
|---|---|
| Real capability responses omit practice headers; rediscovery through a linked client prevented initial loading | Capability discovery uses its independent HTTP contract. A missing-header regression and real-backend native journey verify the fix. |
| Recreated JSON encoders can change key order across exact extension retries | Encode deterministic sorted keys; timeout/relaunch assertions compare complete request bytes and idempotency headers. |
| Missing revisions could be treated as revision zero; deletion receipts were not bound | Require an explicit valid revision and expected instance on linked successes, including deletion receipts. |
| Accepted data loaded from disk needed the same identity/series validation as a fresh response | Revalidate restored accepted bundles before cache publication; retain the attempt on failure. |
| A late accepted extension could regress a newer canonical refresh | Compare revision strings as checked `Int64` values and replay the preserved request for a current result. A controlled request barrier verifies no newer facts disappear. |
| Mutation could use stale service bindings or lose linked headers after token changes | Check cached binding before extension creation/linked lifecycle changes, reset bindings on relocation, and preserve linked context when changing tokens. |
| A malformed inherited collection could publish contradictory end dates or creation coverage | Validate derived end date, roots/parents/origins, increasing finite durations, histories, aliases, contributors, and duplicate identities. |
| Recovery controls offered acknowledgement for an uncertain request | Show acknowledgement only for definitive notices; show check only for retryable attempts. Add global Pending Changes visibility. |
| An unreadable session journal could leave unknown pending work while allowing a new extension | Refuse new extension creation until the journal is recovered; assert no POST and preserve original bytes. |
| A malformed completion receipt could acknowledge the wrong outcome | Require the linked receipt's vow identity and resulting state to match the requested transition before acknowledging success. |
| New native/cursor tests initially failed in their fixtures | Return to the top of detail before logging after history; install paging callbacks outside main-actor isolation. Rerun the affected journeys and complete core suite. |
| Native assertions passed, but Xcode stalled closing result bundles | A process sample located the wait in `collectSimulatorDiagnostics`. Disable automatic verbose simulator diagnostics with the supported `-collect-test-diagnostics never` option; keep test results, logs, and screenshot attachments. |
| Reports could label unfinished core tests or unsuccessful commands as passing, or hide an unreadable second native bundle | Require core completion events, retain command exit statuses, and merge console results for unreadable bundles. Regression tests cover each failure mode. |
| Conversation XCTest cases were absent from the core summary, and a second screenshot export could replace the first manifest | Include XCTest results and export attachments into separate suite directories. Regression tests verify both conversation counts and both screenshot manifests. |
| Selecting one native class also invoked an empty unrelated class | Skip the unrelated class when the filter explicitly names ScreenTour or JourneyTests. |

## Verification

Verification uses temporary caches and dedicated throwaway backend databases; no personal practice files or databases are used. The native journey creates a 40-day vow, seeds 30 historical facts, extends to 90 days, deletes a shared fact, logs through the extension, checks both histories, completes the original independently, verifies its win, and relaunches.

Final verification: [complete passing report](../../../app/build/test-runs/2026-10-07-234259/report.md).

- **212 package tests passed:** 95 domain/application tests, 106 storage/protocol/reliability tests, and 11 conversation XCTest cases. All are included in the report.
- **24 native checks passed:** 12 ScreenTour checks and 12 JourneyTests checks, including the linked-extension journeys in normal appearance and dark mode with accessibility text.
- **Generic iOS Release build passed**, with signing disabled for verification.
- **8 reporting regression tests passed**, covering missing results, incomplete tests, unsuccessful commands, mixed readable/unreadable bundles, conversation test counts, and separate screenshot manifests.
- Shell syntax validation and `git diff --check` passed.

The complete harness exited successfully. Both native result bundles finalized and exported their screenshots, superseding the earlier interrupted runs. Sampling the stalled Xcode process located its wait in automatic simulator diagnostics collection; disabling that collection resolved the hang without disabling ordinary test logs, results, or screenshot attachments.

Normal and dark-mode/accessibility screenshots were visually reviewed for the total-duration preview, completion message, and ongoing extension. In normal appearance, linked duration/state navigation shows the completed shorter vow beside its ongoing extension. Accessibility text wraps into scrollable content and the completion message remains readable. The gallery retains captures from both native suites.

No celebration artwork, new conversational tool, import workflow, or app consolidation was introduced.
