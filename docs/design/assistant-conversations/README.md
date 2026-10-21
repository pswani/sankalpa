# Assistant conversations — design

**Status:** Implemented; local verification and remaining device acceptance are in the [implementation review](implementation-review.md).
**Date:** October 21, 2026.  
**Scope:** The connected iOS app in `app/`; existing assistant service. `app2/` is not affected.

## 1. Requirement and decision

The user must be able to start a new Assistant conversation, continue the current conversation,
and reopen an earlier conversation. Opening Assistant continues the last selected conversation.
A visible **New conversation** action starts a fresh conversation; **Conversations** opens history.
Starting fresh preserves earlier conversations and all recorded practice data. A proposal stays
with the conversation that created it and still requires explicit confirmation.

The accepted functional scope is recorded in [conversation requirements](../../requirements/assistant-conversations.md).
The policies below describe the implementation contract for that scope.

This is a client conversation library over the existing AG-UI `threadId`. It adds no domain
aggregate, server transcript store, model memory service, account, or cross-device synchronization.
The library belongs to this installation and persistent service instance. Older devices do not
see it. Local history is not a backup of the authoritative practice.

Related documents: [review and dry runs](review-and-dry-run.md),
[base architecture](../conversational/architecture.md), [contracts](../conversational/contracts.md),
[batch proposals](../conversational-batch-sessions/README.md), and
[client reliability](../session-reliability/README.md).

## 2. Analysis of the existing implementation

| Evidence | Consequence |
|---|---|
| `AssistantView` owns one `@State AssistantSession` and constructs one `Assistant/<serviceInstanceId>-linked-v1.json` recovery URL. | Reopening restores one conversation; there is no library or picker. |
| `AssistantSession.init` restores the saved `threadId`, transcript, proposal, confirmation ID, and recovery input. | Generating a new view or UUID alone still reloads the old checkpoint. |
| `saveCheckpoint` retains only the latest 80 display messages. | Migration cannot recover older messages that were already discarded. |
| `RootView` exposes Assistant only while service capability/reachability allow it; the view calls `recover()` on appearance. | Local browsing needs a different availability rule; opening history must be separated from request delivery. |
| `ConversationController.validate` accepts at most 20 user/assistant messages, each at most 16,000 Java UTF-16 code units; resume has no messages. | Display history and model history must be separate; sending the whole saved conversation is invalid. |
| `ConversationCoordinator` replays a proposal by source run ID and looks for a pending proposal by thread. | A new thread isolates pending proposals without a new server endpoint. |
| Pending-thread lookup can return its existing proposal rather than interpreting a new message. | The client must resolve its card first; do not depend on an ordinary message being rejected. |
| Server proposal resolution uses thread/proposal/confirmation identity and revalidates practice. | Preserve all identities across switching, retry, migration, and restart. |

The coordinator does not store general text responses for exact replay. An interrupted ordinary
run may generate different answer text when retried; proposal and confirmed mutation replay have
stronger guarantees. The UI must not promise exact text replay.

## 3. User experience

### Entry and navigation

- First use opens an empty composer titled **New conversation**.
- Later visits open the last selected conversation, even if a different conversation has newer
  activity. Selection and activity are different concepts.
- The chat toolbar contains **Conversations** and **New conversation** with accessible text labels.
  Existing Back returns to the previous practice tab.
- New selects a persisted empty conversation with a new `threadId`. If the current conversation is
  already empty, has no draft or pending work, reuse it; repeated taps do not produce empty rows.
- Opening Conversations presents a list and a New conversation action. Selecting a row returns to
  that chat. Dismissing the list leaves the current selection unchanged.
- Each row shows title, last activity date/time, a bounded plain-text preview, and a status when
  relevant: Draft, Awaiting confirmation, Needs recovery, or History unavailable.
- Sort by descending activity, then creation time and UUID for deterministic ties. Selection alone
  does not change activity or reorder the list. A first empty conversation is shown as New conversation.
- A one-line note says **Conversations are saved on this device.**

Use the first sent user message as a deterministic title: trim whitespace, collapse line breaks
and repeated whitespace, and retain at most 60 grapheme clusters with an ellipsis if truncated.
Do not make a model call to generate a title. A later reply does not rename a conversation.
Preview is the latest non-empty visible message, at most 100 grapheme clusters; for a draft-only
conversation use its draft. Timestamps use the device's normal date/time presentation. Proposal
expiry continues to use its server timestamp and execution is decided by the service.

### Drafts, speech, and empty conversations

Keep a separate unsent composer draft per conversation. Stop speech before switching, creating a
conversation, leaving Assistant, or presenting history. Apply final recognition only to the
conversation and speech generation that started it. Persist the reviewed draft before navigation.
Draft edits stay in memory while typing; save after a short debounce, on editing end, on navigation,
and on scene background. Force termination can lose edits since the last successful save; show
save failures and do not claim an unsaved draft is durable.

An empty conversation can be reused. Once a draft or sent message exists, New preserves that
record. An older empty record may remain visible; no automatic deletion is needed.

### Pending proposals

Leaving A while A awaits confirmation does not cancel or confirm it. B starts with a blank
transcript, blank composer, and no proposal. A's row retains Awaiting confirmation. On return,
show A's exact canonical proposal and original expiry. An elapsed expiry makes Confirm unavailable
and labels it **Expired — ask again**; this display check must not override an uncertain submitted
confirmation. Use a cancellation resume to settle an unsubmitted expired card before an ordinary
follow-up; do not erase it locally and assume the service has released its pending state.

For an expired unsubmitted card, **Ask again** explicitly settles it with the cancellation resume
then returns the user to the composer; opening the card alone performs no request. If offline,
keep this action disabled with the connection explanation. A locally elapsed timestamp never
replaces a server-recorded result.

Confirm and Cancel are enabled only in the owning selected conversation, under existing service,
capability, repeat-log, and pending-practice checks. A new conversation is not a way to bypass
those checks. Two different pending proposals may exist on different threads. Executing one
may make another stale; the server's existing revalidation remains decisive. Opening a card never
renews its lifetime or submits a decision. Unknown proposal versions remain non-confirmable.

### Active runs and uncertain outcomes

One Assistant request is active at a time in this installation, across all conversations.
While it is active, disable New and selection of another conversation, with **Finish this response
before switching conversations** as supporting text. The list may be inspected. Stop speech
before sending. Navigation to a practice tab may continue; the controller, not the chat view,
owns the task and records its outcome in the original conversation. Do not introduce background
execution; ordinary iOS suspension can still interrupt delivery.

An interrupted or uncertain request becomes Needs recovery. Browsing, switching, and creating an
empty conversation remain possible, but all new assistant network actions are blocked until that
request is settled. Show a persistent **A conversation needs recovery — Open conversation** action
across Assistant screens; do not leave a disabled Send with no explanation. This conservative
installation-wide gate prevents a new preview against a potentially committed but unrefreshed
practice. A pending proposal that has never been submitted for resolution is not uncertain work
and does not take this gate.

Opening a conversation never sends a request automatically. Recovery is explicit through **Retry
request** in its owning conversation and uses the saved logical request, including its run ID and
confirmation ID when present. A definitive terminal refusal may clear uncertainty, but ambiguous
transport/server failures retain it. Use the settlement rules below; never classify every terminal
SSE error or HTTP failure as proof that no action committed. Recover interrupted cancellation before allowing correction,
Edit, or a new action. No automatic recovery of every history row on launch.

A saved queued correction can continue automatically only within the same uninterrupted,
user-initiated cancel-then-send flow. Persist the cancellation outcome and correction as a draft
before allocating its ordinary follow-up request. After relaunch or an interrupted flow, show the
saved correction for explicit Send. An Edit intent restores a reviewable native form only after
acknowledged cancellation; never submit the form automatically.

Recovery settlement rules:

| Evidence | Persisted transition |
|---|---|
| Valid terminal success with proposal | Save the proposal, clear unresolved input; Awaiting confirmation. No mutation has been approved. |
| Valid terminal confirmation success | Save outcome, clear unresolved input, set refresh-needed; reconcile practice before new delivery. |
| Matching explicit proposal-expired/rejected/stale refusal | Save refusal, remove actionable card and unresolved input; allow a new ordinary request. |
| Proposal not found after a submitted decision | Disable the card, reconcile authoritative practice and retain an outcome warning; missing recovery evidence does not prove no save. |
| Already-resolved response inconsistent with saved decision | Disable the card and reconcile authoritative practice, retaining a visible outcome warning. Do not describe it as proof that nothing was saved or retry with a new decision. |
| Documented interpretation/protocol refusal or pre-delivery rejection proving no execution, with no submitted decision | Save failure and restore an editable ordinary request; allocate a fresh run only on explicit resubmission. |
| Timeout, EOF, generic server error, malformed stream, or terminal-result storage failure | Preserve exact unresolved input; Needs recovery. A terminal frame alone is not sufficient settlement evidence. |

Confirmation replay is evaluated before local expiry. An unsupported saved negotiation requires
an update/compatible service, not a downgrade of the saved request. Use current credentials only
after verifying the original persistent instance and supported original negotiation.

Do not provide **Discard request** for an uncertain outcome in this version. It may have committed.
Manual practice reads remain available; recovery errors give a concrete retry or update-app path.

### Offline and disabled Assistant

After a service instance has been identified, keep Assistant entry available for its saved local
history even when offline or server Assistant capability is disabled. Mark history as read-only
for network actions; show the existing service status explanation. Local New and draft editing
remain available and send nothing. Enable Send/Confirm/Cancel/Retry only after current reachability,
authentication, supported capabilities, matching service identity, and existing practice preparation
checks succeed. First-ever connection failure still uses the app's existing connection recovery
screen. No offline request queue is added.

## 4. Ownership and components

| Component | Responsibility |
|---|---|
| `AssistantConversationController` (main-actor observable) | Service-bound library, selected ID, drafts, single active request/recovery gate, navigation and publication guards. Owned alongside `AppModel`, beyond the lifetime of an Assistant view. |
| `AssistantSession` (existing, refactored) | One thread's run/proposal state; construct from an explicit record, never from a shared recovery filename. Own no independent competing checkpoint writer. |
| `AssistantConversationStore` (actor) | Versioned local files, validated load, atomic record replacement, selection, serialized writes, and migration. Performs encoding and file I/O off the main actor. |
| `AssistantView` and conversation list | Render selected record/controller state and request explicit actions. Do not create networking sessions on view appearance. |
| Existing `AGUIClient`, `AppModel`, service coordinator and proposal service | Transport, current practice preparation/refresh, proposal identity/replay and domain validation. |

Keep one selected in-memory session plus the active request's owning session; load other records
on demand. List metadata is derived from records. On opening a service library, validate all record files
off the main actor before enabling delivery, so unselected recovery work cannot be missed. Do not introduce a database or independent
mutable conversation index in this first version.

Before every asynchronous operation capture service instance, binding generation, thread ID,
record revision, and run ID as applicable. A completion updates only its owning record. Screen
publication and navigation require the same current binding and selected conversation. Revisions guard local writes; a valid run
completion merges into the latest owning record while retaining newer draft-only changes, rather
than dropping a valid result just because typing advanced the revision. Do not
reconstruct clients with a different destination halfway through a request.

## 5. Local persistence contract

Use Application Support under `Assistant/Conversations/v1/<serviceInstanceId>/`:

| File | Contents |
|---|---|
| `<threadId>.json` | One versioned conversation record; filename, embedded thread ID and embedded service ID must agree. |
| `selection.json` | Version, service ID, selected thread ID, and optional legacy-import receipt (thread ID plus source digest). |

A conversation record contains schema version, service instance UUID, thread UUID, monotonically
increasing record revision, creation/activity timestamps, full display transcript with stable
message IDs/roles, draft text, pending proposal with expiry, pending confirmation ID, last completed
run ID, unresolved request if any, queued correction/Edit intent if any, last visible error, and
saved-but-refresh-needed status. A request records its kind (ordinary, confirm, cancel), complete
logical AG-UI input and negotiated profile/practice/proposal capabilities. Request presence identifies
unresolved delivery; the active running phase is controller state. Terminal application identity is
the last completed run ID plus returned stable transcript IDs. The saved proposal/error and
refresh-needed flag distinguish an actionable proposal, settled outcome and refresh-only recovery;
navigation effects are deliberately not persisted for replay. Credentials and endpoint URL
are not persisted in these records. Use current Keychain credentials for the same verified service.

Persist all future display messages; do not continue the legacy rolling 80-message truncation.
Render lazily and load only a selected conversation's full transcript. Large-library performance
is a delivery check, not a reason to silently discard history. There is no automatic history
pruning or fixed retention period. Disk/encoding failure blocks actions needing a durable write,
keeps the previous record, and gives a visible storage error. History deletion, export, search,
manual rename and cloud synchronization are deferred; this feature adds no destructive history UI.

Use ordinary atomic same-directory file replacement, existing iOS data-protection policy, and
exclude conversation files and retained migration input from device backup. Never log transcript,
draft, proposal payload, or credentials. Validate schema, identities, unique message IDs, allowed
roles, request/thread binding, and proposal decoding before accepting a record. A schema newer than
the app is preserved and requires an app update, never rewritten with defaults.

### Atomicity and write ownership

Serialize all mutations through the store; one authoritative revisioned writer per record.
A debounced draft write based on revision 7 must not overwrite a request checkpoint at revision 8.
Merge a draft-only patch into the current record or reject the stale patch. Main-actor serialization
alone is insufficient across file/network awaits. UI actions wait for their required save result.

Create/select ordering: save a new record first, then atomically save selection, then publish the
new screen. If selection fails, keep the previous screen and report failure; a valid orphan record
can be listed on restart. Selecting an existing record first flushes the outgoing draft, saves the
selection pointer, and then publishes. There is no two-file transaction claim.

A missing/invalid selection pointer never destroys records. Fall back deterministically to the
most recently active readable record; if none exist and there are no damaged files, create an
empty record. List damaged files by filename as History unavailable without rewriting them.
Damage to a record may conceal a submitted request, so it blocks new assistant network actions
for that service, while readable history and manual practice remain usable. Do not silently skip
an unreadable record and treat the service as having no unresolved work. A bad pointer alone,
when every record validates, does not block network delivery.

### Request delivery and result order

1. Verify active/recovery gates and current service binding; run existing practice preparation.
2. Freeze input from this thread only. For a confirm, allocate confirmation ID once; for a new
   logical request allocate run ID once. Save the user message/draft transition, queued intent,
   and complete unresolved input atomically in the owning record **before** network delivery.
   On failure retain the unsent composer and send nothing.
3. Publish running state and deliver the captured request. Buffer correlated SSE content; never
   treat partial text as a completed response or partial tools as executable actions.
4. At the terminal event, merge response messages by stable message ID and save proposal/result,
   last completed run ID and refresh-needed state in one record replacement. If save fails,
   retain the original unresolved checkpoint, gate new delivery, and offer retry. Do not execute
   navigation before the result is durable.
5. For a mutation result, refresh authoritative practice through the captured service binding.
   Clear refresh-needed only after refresh succeeds and that acknowledgement is saved. Persisted
   refresh-needed work blocks new assistant delivery until practice reconciliation succeeds.
   Refresh failure does not undo or resend the mutation. Plain navigation effects execute only
   for the still-selected thread under the current binding; never replay navigation on launch.
6. Clear uncertainty only after a durable terminal outcome (and reconciliation where needed).
   Retrying a checkpoint merges stable message IDs so a resolution is not shown twice. An ordinary
   answer can differ on retry because the service does not retain general text responses.

Represent send preparation as a controller reservation so double taps cannot both enter step 1.
On relaunch an unresolved input is Needs recovery, never automatically delivered. Retrying uses
its exact original input; do not rebuild it from a modified draft or newly selected conversation.
A pending proposal plus unresolved confirmation/cancellation takes precedence over an actionable
proposal card. Do not offer a different decision until the uncertain decision is settled.

## 6. Service boundaries and migration

A service's persistent instance UUID, not its hostname or bearer token, scopes the library.
Changing location for the same verified instance retains history. Token rotation retains history
but invalidates the old client/binding generation. Connecting to another instance selects only
that instance's library. Reusing a hostname for a replaced data store never imports old history.

Before changing a binding, flush drafts and finish or locally interrupt the owned task. Preserve
its unresolved input in the original service record; interrupting a stream does not cancel a
server action. Increment the binding generation before publishing the new binding. A late
completion may be retained under its original service but cannot change current practice, current
selection, or navigate the new screen. Reconnecting the original instance exposes its recovery.
Uncertainty in service A does not block service B's independent practice.

Migration from `Assistant/<serviceInstanceId>-linked-v1.json` runs only for the currently verified
matching service, through the serialized store, before network actions:

1. If a valid selection manifest has a legacy-import receipt, migration is already complete.
2. Read the legacy bytes without modifying them; decode and validate the existing checkpoint.
   Preserve original thread, message, proposal, confirmation and unresolved request identities.
   Missing historical metadata gets the captured legacy file modification time as deterministic
   creation/activity values and a first-message title; draft is empty because the old format did not save it. Missing parent run ID stays absent.
3. Write/read-validate the new record using the same thread UUID. If this destination already
   exists after a crash, accept only the identical migration payload; never overwrite a divergent
   newer record with the old checkpoint. A divergent collision requires recovery.
4. Write selection and the import receipt together atomically. Only then expose the migrated
   record and permit normal mutations. Keep original bytes excluded from backup as migration
   evidence; the receipt prevents re-import. Never delete the old file as the first step.
   Legacy input has no saved transport headers: mark negotiation as inferred using only deterministic
   minimums from the saved proposal. The first explicit retry against a verified service freezes
   compatible current headers before delivery, preserving the complete original AG-UI input.
   See the [implementation clarification](implementation-review.md#migration-clarification).
5. A crash before step 4 repeats safely from the original bytes; after step 4 the new library owns
   the conversation. Imported display history is limited to whatever the old checkpoint retained;
   show **Earlier messages may be unavailable** on imported conversations.

If the old checkpoint or migration receipt cannot be validated, preserve files and block network
actions for that service with a recovery explanation. Never create a fresh actionable library as
an implicit workaround. If the legacy file exists and a receipt is missing while other new records already exist
(other than the exact staged import), require
recovery rather than guessing whether the legacy file is current. Downgrade to an older app and
subsequent edits to its legacy checkpoint are unsupported; do not merge two writers.

## 7. Protocol and architecture impact

No new server endpoint, proposal schema, capability flag or database migration is needed solely
for selecting conversations. All calls continue through `POST /api/v1/assistant/runs` with the
existing supported profile and negotiated proposal capabilities.

| Value | Rule |
|---|---|
| `threadId` | Fresh for New; stable when continuing, selecting, migrating, or retrying. |
| `runId` | Fresh per logical request; retain the original on uncertain retry. |
| `confirmationId` | Allocate once per confirmed proposal decision and retain on replay. |
| `parentRunId` | Last completed run in the same conversation when known; no link to a previous conversation. An exact retry preserves the original parent. |
| Ordinary `messages` | Latest at most 20 allowed user/assistant messages from this thread, latest user message last; obey existing message/body limits. |
| Resume `messages` | Empty; use the original thread and proposal identity. |

The full transcript is display history, not model memory. Show **Earlier messages may be outside
the assistant's context** after the request window is exceeded. Use advertised compatible limits capped by this supported profile. Validate per-message UTF-16 length
and the encoded HTTP body limit before saving a deliverable request. Do not truncate the current
user message silently; keep it editable with a limit explanation. Drop oldest context messages
as needed to fit the existing request byte budget (currently 262,144 bytes including the whole JSON envelope), retaining the current message. If it alone
exceeds the budget, send nothing. Titles, previews, drafts and other threads are never injected
into model instructions or combined history. New still loads current authoritative practice on
the server; it clears chat context, not the user's recorded practice.

An old pending proposal remains server-owned until resolved or expired. Starting B sends no
cancellation for A. Returning to A may yield expiry or stale-preview refusal; keep that explanatory
outcome in A and require a fresh request/approval. Local selection never changes server authority.

The DDD model, session ledger, transaction boundaries, SQLite/DynamoDB persistence and AWS deployment
are unchanged. Only client presentation and reliability storage gain conversation multiplicity.

## 8. Delivery and acceptance

Implement store/fixtures and migration first; then refactor session persistence ownership; then
add controller, selection/list UI and offline history visibility; finally integrate retry,
service-binding and accessibility journeys. Do not roll out a New button that merely resets the
in-memory view while leaving the shared recovery path intact.

Required deterministic tests and UI walkthroughs:

| ID | Scenario | Acceptance evidence |
|---|---|---|
| AC-01 | First entry, leave/reopen, relaunch | Same selected thread restored; appearance makes zero assistant requests. |
| AC-02 | A has text/draft; New B; return A | New UUID and isolated context; A's transcript/draft intact; no practice mutation. |
| AC-03 | Repeated New on untouched empty B | Same empty thread reused; no extra rows. |
| AC-04 | History rows | Stable title, date, preview, deterministic sort and accessible status; selecting does not reorder. |
| AC-05 | A awaits proposal; B starts and executes | A preserved; B has no A proposal/history; stale A requires reapproval. |
| AC-06 | A expires or is unsupported | No generic Confirm; original expiry retained; settle original thread before follow-up. |
| AC-07 | Active A; rapid New/switch/Send taps | One request reservation; switching disabled; no duplicate input or misrouted response. |
| AC-08 | Send/Confirm/Cancel response lost | Exact persisted input/IDs; recovery gate across library; retry only by explicit action. |
| AC-09 | Crash before delivery / after commit / after terminal save | Original input replay or saved result plus refresh; no duplicated mutation or resolution bubble. |
| AC-10 | Cancellation and queued correction/Edit interrupted | Decision retry first; follow-up never sent in another thread or before cancellation acknowledgement. |
| AC-11 | File write fails at each boundary | No send before durable request; old bytes remain; no lost confirmation identity or false success. |
| AC-12 | Draft debounce races terminal result | Revision/patch rules preserve result and current draft; no old checkpoint restored. |
| AC-13 | A service changes URL/token; A replaced by B; late callback | Same-instance history retained; different-instance separation; no stale navigation/practice publication. |
| AC-14 | Offline or capability disabled | Local history/drafts work; no queued or automatic network delivery; manual practice unaffected. |
| AC-15 | Legacy pending/uncertain input, corrupt file, every migration crash point | Same identities imported exactly once; old bytes intact; damage/collision fails closed. |
| AC-16 | Damaged selection vs damaged record, unknown schema | Pointer fallback only when records validate; hidden uncertain work cannot be bypassed. |
| AC-17 | More than 80 displayed / 20 request messages, multi-byte oversized input | Full new display history; bounded single-thread request; UTF-16/body limit rejection before delivery. |
| AC-18 | Speech partial arrives after switching | No draft contamination; typing-only, VoiceOver, Dynamic Type and focus journeys pass. |
| AC-19 | Saved result but refresh fails, including relaunch | Refresh-needed persists; retry refresh only; saved mutation never reinterpreted or resubmitted. |
| AC-20 | Many long conversations / storage exhausted | Lazy UI remains responsive, I/O off main actor; no automatic pruning; actionable save error. |

Retain existing assistant/protocol, single/batch proposal, linked contribution, repeat-log and
confirmation replay tests. Use the current fake model and scripted streams before any live model
or device acceptance. Source checks confirm no backend behavior change is needed; existing backend
contract/replay tests remain regression gates. The original dry runs are design evidence; executed tests and implementation fixes are in the
[implementation review](implementation-review.md). See the [design review record](review-and-dry-run.md)
for the preceding analysis and design fixes.
