# Backlog

Feature-specific requirements and remaining acceptance work are maintained in the linked
documents below.

## Implemented: Assistant conversations

Implemented explicit New conversation and a local Conversations list while entry continues the
last selected chat, preserving per-thread drafts, pending proposals and request recovery. The
[requirements](requirements/assistant-conversations.md), [design](design/assistant-conversations/README.md),
and [Analyze → Design → Review/dry-run → Fix record](design/assistant-conversations/review-and-dry-run.md)
describe the delivered behavior in the connected iOS app. See the [implementation review](design/assistant-conversations/implementation-review.md)
for executed tests, review fixes and remaining real-device speech/VoiceOver/performance acceptance.

## Completed: linked sankalpa extensions

Implemented in the backend and connected iOS app. A finite ongoing sankalpa can be extended
into a longer linked vow. Sessions contribute to every eligible vow in the series, preserving
session identities and avoiding duplicate session copies.

The original cloning/copying proposal is superseded by the
[linked-extension requirements](requirements/linked-sankalpa-extensions.md) and
[detailed design](design/linked-sankalpa-extensions/README.md).

For remaining AWS recovery, device workflow and billing checks, see
[the implementation review](design/aws/implementation-review.md#remaining-acceptance).
