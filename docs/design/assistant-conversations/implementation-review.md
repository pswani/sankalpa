# Assistant conversations — implementation review

**Date:** October 21, 2026. **Scope:** connected iOS app (`app/`) and its Swift package.
**Status:** Implemented; local verification recorded below. No production data was changed.

This records the requested implement → write tests → review → fix → test → fix loop. Reviews
were performed by the author against source, deterministic failure tests, native journey results
and captured screenshots. The [design review](review-and-dry-run.md) remains the historical design
record; this document records executed implementation evidence.

## Delivered behavior

Assistant reopens the last selected conversation and provides **New conversation** and
**Conversations**. Each chat preserves its transcript, draft, proposal and request identity.
Untouched empty chats are reused. History has deterministic titles, previews, dates and statuses;
selection does not reorder it. Future display history is retained independently from bounded
model input. Local history/drafts remain accessible offline and when Assistant is disabled.

`AssistantConversationController` is held by `AppModel`, beyond the view lifetime. It reserves
requests before asynchronous preparation or a rapid-repeat confirmation prompt, gates active and
uncertain requests across the library, and exposes explicit recovery. A saved confirmation result
requiring practice reconciliation retries refresh only. A selection or view appearance never
sends a request. Speech updates belong to their originating conversation and recognition generation.

`AssistantConversationStore` is an actor and the sole file writer. It validates every record before
delivery, stores revisioned per-thread files and selection, merges draft/result updates atomically,
and preserves damaged/future-schema data. The old checkpoint migrates with original thread,
message, proposal, run and confirmation identities. Service/binding checks and interruption prevent
old requests or navigation from affecting a newly connected practice.

No backend endpoint, database schema, domain aggregate or practice mutation capability was added.
Existing proposal approval, domain validation and server replay remain authoritative.

## Implementation and review loop

| Cycle | Finding | Fix and executed evidence |
|---|---|---|
| 1 — Implement and unit test | Existing view-owned session and single checkpoint could not represent history; old tests assumed re-confirming an uncertain decision. | Added record/store/controller and explicit Retry request. Adapted existing recovery tests without weakening identity assertions; added selection, per-thread context, proposal and offline tests. |
| 2 — Migration/failure review | A staged import file URL compared unequal because directory enumeration normalized its URL differently. A byte-budget test accidentally allowed its supposedly oversized fixture. | Compare filenames inside the fixed service directory; test failure before record write and before import receipt. Corrected test input to exceed the encoded budget and made unexpected scripted requests fail without crashing the runner. |
| 3 — Race and outcome review | Draft patches could race a response between load and save; a late summary could publish an older gate state. New confirmation/cancellation could be offered after an uncertain response. | Atomic actor update for terminal results/refusals/refresh, revision-conditional summary publication, exact-input recovery and request reservation. Concurrent draft patch/result merge, decision identity, suspension, repeat-policy reservation and refresh-only tests pass. |
| 4 — Native UI review | Offline app banner overlapped the chat toolbar; tapping history opened Pending Changes. Eager audio initialization delayed a typing-only chat. | Render Assistant notices inside its navigation content and keep a local pending-practice action; create speech/audio resources only when used and avoid deactivating unused audio. Native journey verifies restart, offline history and both drafts. |
| 5 — Accessibility/visual review | Large-type history needs scrolling; an existence-only test incorrectly required an offscreen lazy row. Standard button tint weakened row text contrast. | Test scrolling and selecting the actual row; use plain row buttons and an inline history title. Inspect captured light/dark/large-type screens and repeat the native journey. |
| 6 — Final contract/storage review | Unknown selection schemas must remain protected even when a user selects readable history. Legacy headers were not saved. Duplicate response IDs could conceal conflicting text. | Reject manifest downgrade during selection, preserve changed legacy input behind a recovery error, mark missing legacy negotiation for resolution on explicit verified retry using current support plus proposal minimums, and reject duplicate/conflicting message identities. Added schema, legacy-change and protocol regression tests; repeat full package, focused UI and Release verification. |

## Migration clarification

Legacy checkpoints contain frozen AG-UI input but **do not contain the transport capability
headers**. Their exact original headers cannot be reconstructed. Recovery uses supported negotiation,
strengthened to the minimum required by a known batch/history-repair card. Import stores only deterministic proposal minimums and marks the missing negotiation as inferred;
the first explicit retry against a verified online service freezes its compatible headers before
delivery. An offline partial import can therefore complete unchanged after reconnecting. This
changes no saved AG-UI request, proposal or confirmation identity. An interrupted
ordinary request that might have produced a history-repair proposal can therefore be recovered by
a compatible client rather than permanently retrying without its required capability. Subsequent
retries preserve that imported negotiation and refuse incompatible downgrades.

A receipt stores the source digest. Changing legacy bytes after import fails closed rather than
merging edits from an older app. A partial identical import can finish after a crash; a divergent
destination or hidden damaged record cannot be silently replaced. Unsupported schemas remain
readable where possible but never become writable defaults.

## Acceptance coverage

| Design acceptance | Executed evidence |
|---|---|
| AC-01–04 | Controller selection/new/draft/relaunch/title/order tests and the native conversation journey. |
| AC-05–06 | Per-thread pending proposal/context isolation, expired-card cancellation, unsupported-card and stale/expired resolution tests. Existing batch/codec cases retained. |
| AC-07–10 | Held-stream reservation/double-send tests; exact ordinary/confirm/cancel retry tests; interrupted correction returns as an explicit draft. |
| AC-11–12 | Injected checkpoint/result/selection/import write failures, stale replacement refusal, concurrent actor draft/result updates. |
| AC-13 | Independent service libraries, old-controller suspension, rejection of late publication and unsupported negotiation downgrade; existing remote service-binding suites. |
| AC-14 | Offline controller tests and real simulator offline relaunch/select/send-disabled assertions. |
| AC-15–16 | Imported uncertain confirmation, crash prefixes, corrupt files, divergent import, changed source, future record/manifest and bad-pointer fallback. |
| AC-17 | Full display history beyond 80 messages, at most 20 wire messages, UTF-16 and encoded whole-body budget tests; existing profile fixtures. |
| AC-18 | Native typing/navigation in light mode and dark accessibility text size; generation/owner checks in speech callbacks. Actual microphone/VoiceOver operation remains a manual device check. |
| AC-19 | Lost confirmation and saved-result/failed-refresh restart tests; reconciliation never reissues the saved mutation. |
| AC-20 | Lazy chat/list UI, actor-isolated file encoding/loading, long-history retention tests and injected out-of-space failures. Very large real-device libraries remain a performance acceptance check. |

## Verification

Final verification uses:

```bash
./app/scripts/test.sh --only JourneyTests/testAssistantConversationsPreserveDraftsSelectionAndOfflineHistory
```

This runs the complete Swift package suites, the focused native conversation journey on the
dedicated test simulator against throwaway local services, and an unsigned generic-device Release
build. It does not run the full legacy native journey/screen-tour corpus or mutate a live practice.
Final run: `app/build/test-runs/2026-10-21-144649/report.md` (local build artifact).

| Check | Result |
|---|---|
| Complete Swift package | **259 passed:** 95 domain, 110 storage/application, 54 conversation/protocol. |
| Focused simulator conversation journey | **1 passed**, including restart, offline selection, dark mode and accessibility text size. |
| Unsigned generic-device Release build | **Passed.** |
| Documentation validation | 121 relative links/anchors across 17 changed/new Markdown files resolve; CR-26–CR-35 and AC-01–AC-20 remain complete; `git diff --check` passed. |

The final screenshots were inspected: conversation rows retain normal primary/secondary contrast,
the offline toolbar is reachable, and the history list scrolls and selects at accessibility size.

A final deterministic file-boundary test also verifies that Retry cannot start while selection
is being saved. Navigation and network actions share the reservation rules, including recovery.

No backend implementation was changed. Existing domain, application, remote storage, protocol,
single/batch proposal and codec tests remain in the package run. Native test compilation also
builds the existing UI suites. Existing unrelated XCTest actor-isolation warnings and the Xcode
AppIntents metadata notice are not new product-code compiler failures.

## Remaining manual acceptance

- Real-device speech recognition and permission interruption, with an on-device supported language.
- VoiceOver traversal/focus and very large real-device libraries.
- Live-provider interpretation with a staging practice; deterministic tests already cover the
  request/proposal/retry boundary without relying on model output quality.

These are explicit limits of local verification, not reasons to send requests to production or
reset a user's history. No automatic history deletion, export, synchronization or recovery-data
discard was added.
