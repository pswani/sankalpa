# Analyze → Design → Review with dry run → Fix

**Date:** October 21, 2026. **Scope:** design and documentation only.

The author reviewed workspace source and walked deterministic state transitions. These are design
dry runs, not independent review, simulator execution, database mutations, or runtime test results.
The [final design](README.md) incorporates the fixes below and its AC matrix defines implementation
acceptance. No application code was changed.

## Cycle 1 — Analyze the current behavior and choose the boundary

Inspected `app/Sankalpa/UI/Assistant/AssistantView.swift`, `RootView.swift`, `AppModel.swift`,
`SankalpaConversation/AssistantSession.swift`, `ConversationClient.swift`, recovery tests, and
backend `ConversationController`, `ConversationCoordinator`, `ConversationRunGuard`,
`ProposalService`, request boundary filter and capability response. Read the base conversation,
batch-session, session-reliability and DDD architecture documents.

Candidate: add New by constructing another `AssistantSession` and putting the old transcript in a list.

| Dry run | Finding | Fix |
|---|---|---|
| A exists; construct B with a fresh UUID | Existing initializer reads A from the same service recovery URL and restores its UUID. New would reopen A. | Explicit conversation records and a controller-owned library; one file per thread. |
| B points at another recovery file but list is only in memory | Relaunch loses discoverability/selection and cannot locate pending work. | Derive rows from durable records; separate validated selection pointer. |
| Treat history as a server aggregate | No server text archive exists; proposal persistence already supplies mutation safety. | Keep this change in iOS presentation/reliability; use existing thread and proposal contracts. |

Retest: first entry produces A; New saves/selects B; reopening A uses A's original thread; restart
restores B. Zero server calls occur for these steps. New cannot inherit A's pending proposal.

## Cycle 2 — Persistence, drafts and migration

Candidate: write each record atomically and update selection independently; preserve the legacy file.

| Dry run | Finding | Fix |
|---|---|---|
| New B writes selection, then disk fills before record save | Selection points at a nonexistent chat. | Save record, then selection, then publish. Pointer failure leaves an inspectable orphan. |
| Draft debounce captures revision 7, response saves revision 8, debounce finishes last | Atomic replacement alone can still overwrite the newer result. | Serialized revisioned writer; draft-only merge or stale-patch rejection. |
| Crash after imported record write but before receipt | Re-running migration with a new time changes its payload and can look like a collision. | Derive fallback timestamps from captured legacy modification time; compare exact import payload. |
| Old checkpoint remains after successful import | A naive file-exists migration restores stale history on next launch. | Atomic import receipt with selection; receipt is authoritative, legacy bytes retained only as evidence. |
| A corrupt unselected record hides a submitted confirmation | Skipping it and sending in B bypasses recovery protection. | Validate every record before enabling service delivery; damage blocks network actions, not readable history. |
| Selection pointer alone is corrupt | Treating it like a hidden request unnecessarily blocks all work. | Rebuild selection from validated records; block only if record/migration uncertainty exists. |

Retest: each crash prefix leaves either the original legacy bytes, a staged identical import, or
a committed receipt/new owner. No step deletes the only copy or allocates new retry identities.
A differing destination is preserved for recovery, never overwritten. Migration can import only
the latest 80 messages that the legacy checkpoint actually retained; future records retain full
transcripts and disclose the earlier-history limitation.

## Cycle 3 — Proposal and uncertain-result walkthroughs

Candidate: allow unrestricted switching and let each reopened view recover automatically.

| Dry run | Finding | Fix |
|---|---|---|
| A confirming; select B; A response arrives | View-owned task can disappear or navigate/refresh B's context. | Controller owns task; one active request per installation; disable New/switch until terminal/interrupted. |
| A's confirmation commits; stream disappears; user opens B | B could create a preview against stale local practice while A's outcome is hidden. | Persist exact unresolved input; service-wide recovery gate and visible Open conversation action. |
| Open history containing five uncertain records | Recover-on-appearance/row construction can send without an explicit action. | No delivery on appearance or scanning; explicit Retry request in owning chat. |
| Pending A has never been confirmed; New B | A global pending-proposal lock would defeat useful independent conversations. | Only active/uncertain/refresh-needed work takes the global gate; A's unsent proposal stays scoped to A. |
| A's displayed expiry elapses after an uncertain confirmation | Clearing the card by the local clock may hide a committed save. | Submitted uncertainty takes precedence; retry original confirmation, not cancellation or a fresh request. |
| Unsubmitted expired A is erased locally, then follow-up sent | Service may still own A's pending proposal. | Explicit Ask again settles through existing cancellation before returning to composer. |
| Cancel is acknowledged; crash before queued correction sends | In-memory correction can be lost or replayed automatically on launch. | Save correction as a draft with cancellation outcome; after interruption require explicit Send. |
| Commit result is saved; refresh fails; app restarts | Recovery must not reinterpret/resubmit a saved mutation. | Durable refresh-needed marker; retry only authoritative refresh before new delivery. |

Retest sequence: A proposes P; New B leaves P intact; B executes Q; return to A and confirm P.
The existing server may reject P as stale; A displays refusal and needs a new preview/approval.
No automatic cancellation, session copy, or cross-thread resume occurs. For lost confirmation,
retry preserves thread/run/proposal/confirmation identities; stable result message IDs merge once.
Ordinary text replay can differ, which is now stated explicitly.

## Cycle 4 — Service, availability and bounded context

| Dry run | Finding | Fix |
|---|---|---|
| Same service moves URL or rotates token | URL/token-scoped history would strand or reset chats. | Persistent service instance scopes files; binding generation invalidates old callbacks. |
| Hostname reused for another database | Host-scoped library could replay a decision into another practice. | Verify instance before delivery and select that instance's own library. |
| Old callback returns after rebinding | A selected-thread check alone is insufficient. | Check service, binding generation, owning thread/revision/run; no stale practice publication or navigation. |
| Offline/disabled Assistant | Existing tab disappears, hiding local history. | Keep entry for known local library; independently gate every network action. |
| 81 display messages and 21 model messages | Keeping old 80-message truncation loses history; sending all messages violates controller bounds. | Full future display transcript; latest at most 20 model messages from owning thread. |
| 20 individually valid multi-byte messages | Count/character validation alone can exceed encoded request-body limit. | Drop oldest context until entire JSON fits 262,144 bytes; never silently truncate the new message. |
| Late speech partial after New | Recognized words may populate another draft. | Stop speech and guard recognition by originating thread and speech generation. |

Retest: local New/switch/list sends zero requests offline. After reconnection, preparation uses the
current matching instance and same-thread context only. New chat has no old chat messages but can
read current practice through normal server context. Long display history stays readable without
claiming that the model receives every prior message.

## Cycle 5 — Final result classification and publication pass

The final record-order walkthrough found two additional ambiguities: treating every terminal error
as settled could hide a committed confirmation; checking an exact record revision on a network
completion could discard a legitimate result after a draft edit. The design now includes an
explicit recovery-settlement table and requires merging a validated run outcome into the latest
owning record while revision guards prevent stale full-record replacement. Saved requests also
retain original negotiated capability versions, so retry cannot silently downgrade a proposal.

Retest: A's draft update advances its record while A's response finishes; result merge retains both.
A generic SSE failure leaves the original decision retryable. A known stale-preview refusal removes
the card and allows a fresh explicit request. A missing proposal after a submitted decision or an inconsistent already-resolved response triggers
practice reconciliation plus an outcome warning, without claiming no save or offering a new decision.
Unknown saved negotiation stays preserved behind an update/compatibility explanation.

## Final review assessment

The second pass over persistence and request ordering found the deterministic migration-time,
expired-card and correction-after-crash gaps recorded above. Those fixes are incorporated in the
final design. The final walkthrough found no unresolved design blockers for this scope.

Deliberate tradeoffs: local-only history, no history management UI in this delivery, one active
request, conservative blocking while an outcome is uncertain, no automatic retry on opening a
chat, no recovery-data discard shortcut, and full future display transcripts with lazy rendering.
A damaged recovery file requires repair or a future explicit recovery workflow; this feature does
not invent an unsafe discard to make Send available. These limits are visible in the design.

Implementation must prove AC-01–AC-20 with store/controller/scripted-stream tests and native UI
acceptance, including disk failures and service rebinding. Existing proposal replay and domain
suites remain required. The design review does not assert those tests have already passed.

## Documentation verification

Executed a standard-library documentation check across all 14 changed/new Markdown files:
all 95 relative links, including explicit heading anchors, resolve. CR-26–CR-35 and AC-01–AC-20
are unique and complete, and the review contains five numbered cycles. `git diff --check` passed.
The changed-file inventory contains only documentation. No runtime tests were run for this
documentation-only change; implementation acceptance remains outstanding.

## Implementation follow-up — October 21, 2026

The conversation library is now implemented. The [implementation review](implementation-review.md) records
executed test results, subsequent review fixes and remaining manual device acceptance. Earlier
statements about implementation being outstanding describe the preceding design review.
