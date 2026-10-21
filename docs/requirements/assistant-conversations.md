# Assistant conversations

**Functional scope accepted:** October 21, 2026.  
**Delivery status:** Implemented in the connected iOS app; see [local verification](../design/assistant-conversations/implementation-review.md).

The user needs an explicit choice between beginning a fresh Assistant conversation and continuing
an existing one. The accepted direction is to reopen the last selected conversation on entry,
provide New conversation, and provide a history list for reopening earlier conversations.

| ID | Requirement | Design acceptance |
|---|---|---|
| CR-26 | Opening Assistant continues the last selected conversation; first use opens an empty conversation. | AC-01 |
| CR-27 | A visible New conversation action starts fresh chat context while preserving previous conversations and recorded practice. | AC-02–03 |
| CR-28 | Conversations lists locally saved chats with a short title and last activity; selecting one continues it. | AC-04 |
| CR-29 | Each conversation retains its own transcript, unsent draft, identity, and pending proposal. Content and confirmation decisions cannot cross conversations. | AC-02, AC-05–06, AC-17–18 |
| CR-30 | New, selection, and opening history never confirm, cancel, or resubmit practice changes implicitly. Every proposal still needs explicit approval. | AC-01–02, AC-05, AC-08 |
| CR-31 | Restart, migration, and retry preserve request/proposal/confirmation identities and make unresolved outcomes visible. | AC-08–12, AC-15–16, AC-19 |
| CR-32 | Saved conversations are local to this installation and service instance; service changes cannot deliver old work to another data store. | AC-13 |
| CR-33 | Saved history remains readable when the service is unavailable; assistant requests require an online, supported, verified service. | AC-14 |
| CR-34 | Conversation storage failures preserve existing data and explain blocked actions; no implicit deletion or silent reset hides unresolved requests. | AC-11–12, AC-15–16, AC-20 |
| CR-35 | The conversation controls support typing, speech draft isolation, and existing accessibility requirements. | AC-18 |

AC references identify the acceptance matrix in the [detailed design](../design/assistant-conversations/README.md#8-delivery-and-acceptance).
The [review record](../design/assistant-conversations/review-and-dry-run.md) documents analysis,
design revisions, and dry runs. One active request per installation, explicit recovery, deterministic
titles, full future display history and migration policy are design decisions supporting these
requirements. Their implementation and verification limits are recorded in the linked review.

This feature adds no new practice mutation or lifecycle rule. The existing
[Sankalpa requirements](sankalpa.md), [linked-extension requirements](linked-sankalpa-extensions.md),
and [conversational confirmation requirements](../design/conversational/requirements.md) still apply.
Cross-device synchronization, history deletion/export/search, manual titles, and semantic memory
are outside this delivery.
