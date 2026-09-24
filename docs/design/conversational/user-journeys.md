# User Journeys

These journeys describe visible behavior, not model prompts. Any conforming model adapter must
produce the same safe outcomes.

## 1. Entry and input

### Journey 1A — Type a request

1. The user opens **Sankalpa Assistant** from the existing voice/chat entry point.
2. The screen shows recent local conversation, a text composer, microphone, and Send button.
3. The user types a message.
4. Send becomes enabled when trimmed text is non-empty and no run is active.
5. On Send, the user message is added immediately and the UI shows **Understanding…**.
6. The response streams into an assistant message or ends in a native proposal card.

### Journey 1B — Speak a request

1. The user taps the microphone.
2. iOS shows **Listening…**, live recognized words, and a visible Stop control.
3. The user stops or speech recognition reaches a final result.
4. The app returns to the ordinary composer with the transcript still editable.
5. The UI says **Ready to send** and exposes Send. It does not remain in a listening state.
6. The user corrects any transcription error and taps Send.

If speech permission is denied or recognition fails, the composer remains usable and explains how
to retry or type. Audio is not sent to the Sankalpa service.

## 2. Session logging

### Journey 2A — Clear match and exact time

Preconditions:

- “Gym four times a week” exists and was In progress at 2026-09-23 08:15.
- No other plausible gym Sankalpa exists.

Conversation:

> User: I went to the gym today at 8:15.

The service proposes:

```text
Log a session?
Gym four times a week
September 23, 2026 at 8:15 AM

[Cancel] [Edit] [Confirm]
```

Confirm executes the existing `LogSession` use case with a stable session identity. The assistant
reports success, iOS refreshes, and the updated Sankalpa detail is shown. Cancel changes nothing.

### Journey 2B — “I went to the gym this morning”

The date is known but the exact required time is not. The assistant asks one question:

> What time this morning should I record?

After “Around 8:15,” the normal proposal appears. The system never silently chooses a time.

### Journey 2C — “I just finished the gym”

“Just finished” explicitly permits the current server time. The proposal shows that exact time. The
user can edit it before confirmation.

### Journey 2D — Ambiguous Sankalpa

If “Morning gym” and “Strength training” are both plausible, the assistant asks:

> Which Sankalpa should this count toward: Morning gym or Strength training?

The reply must resolve to one current server ID before a proposal is created.

### Journey 2E — No matching Sankalpa

The assistant does not report a transcription failure. It says:

> I couldn’t match that activity to a current Sankalpa. Would you like to choose one or declare a
> new Sankalpa?

The response may include safe UI actions to open the list or begin a declaration conversation.

### Journey 2F — Not eligible at the stated time

The model may identify a target, but the server proposal validator finds it was Paused, Not
started, outside its commitment, or otherwise ineligible at that time.

The assistant reports the domain reason and offers to choose a different time or Sankalpa. It does
not create a confirmable proposal that the domain would already reject.

### Journey 2G — Another recent session

Every conversational session log already requires explicit confirmation, including another log
within one minute. Confirm uses a new stable session identity and records a legitimate second
session; Cancel has no effect. V1 does not add a second, assistant-specific rapid-repeat warning.

### Journey 2H — Domain changes before confirmation

1. A proposal is created while the Sankalpa is In progress.
2. The Sankalpa is paused from another client.
3. The user confirms the old proposal.
4. The server revalidates and rejects execution with the current domain reason.
5. The proposal becomes `REJECTED`; it cannot later be confirmed again.
6. iOS refreshes so the visible state agrees with the server.

## 3. Declaring a Sankalpa

### Journey 3A — Complete declaration

> User: I want to do Vipassana twice every day for 180 days starting tomorrow.

The proposal shows only fields represented by the current domain:

```text
Declare this Sankalpa?
Title: Daily Vipassana
Description: —
Action type: Meditation
Commitment: 2 times per day
Starts: September 24, 2026
Duration: 180 days
Ends: March 22, 2027

[Cancel] [Edit] [Declare]
```

The end date is calculated by domain code, not by the model.

The card also states that declaration creates the Sankalpa in **Not started**. After success, iOS
opens the ordinary detail screen where the existing Begin action remains explicit.

### Journey 3B — Safe defaults

> User: I want to meditate every morning.

The server may infer:

- action type `MEDITATION`;
- once per `DAY`;
- start date today;
- no duration, therefore open-ended;
- a concise title such as “Morning meditation.”

Every inferred value is visible in the proposal. “Morning” is descriptive only; the system does
not invent a stored reminder time.

### Journey 3C — Missing consequential information

> User: I want to exercise more often.

The frequency is not known. The assistant asks:

> What minimum would you like to commit to—for example, three times per week?

It asks only for required information or a choice that cannot be safely defaulted.

### Journey 3D — Duration cannot be represented exactly

> User: Four workouts per week for six months.

The domain stores duration as a whole number of the commitment period. The assistant asks for an
exact number of weeks rather than silently treating every six-month span as 26 weeks.

### Journey 3E — Edit before declaring

The user can:

- reply conversationally, such as “Make that three times per week”;
- tap Edit to open the existing native declaration form prefilled with the proposal;
- cancel.

For a conversational correction, iOS first cancels the pending proposal. After cancellation
succeeds, it sends the correction as a new ordinary message with the prior proposal summary still in
bounded history. Tapping Edit also cancels the conversational proposal before opening the native
form, which uses the existing manual command path.

### Journey 3F — Duplicate confirmation or lost response

1. The user confirms.
2. The server commits the declaration but the response is lost.
3. iOS retries the same resume with the same confirmation ID.
4. The server returns the recorded resource ID and does not declare a second Sankalpa.

## 4. Read-only assistance

### Journey 4A — List current Sankalpas

> User: What Sankalpas am I working on?

The assistant answers from the current bounded server context and may emit `open_sankalpa_list`.
It does not ask the iOS cache for authoritative data.

### Journey 4B — Open a particular Sankalpa

> User: Show me my Vipassana Sankalpa.

If the match is unique, the server emits `navigate_to_sankalpa` with the canonical ID. If it is
ambiguous, it asks which one.

### Journey 4C — Unsupported action

> User: Delete my Vipassana Sankalpa.

Because Sankalpa deletion is outside current requirements, the assistant explains that it cannot
do that. It does not improvise another operation.

## 5. Proposal control

### Edit in a native form

Edit sends the same idempotent cancellation resume as Cancel. After cancellation succeeds, iOS
opens the existing log-session or declaration form prefilled from presentation data. Submitting that
form uses the existing manual command path. If cancellation fails, the proposal card remains and
offers Retry; the app does not open two competing confirmation paths.

### Correct a proposal by chat

1. The user receives a pending proposal.
2. The user sends “No, yesterday at 6 PM.”
3. iOS retains the text locally and sends a cancellation resume for the open interrupt.
4. If the cancellation response is lost, iOS retries the same idempotent cancellation.
5. After cancellation succeeds, iOS starts a normal run with the correction and bounded history.
6. The service interprets the correction with the canonical old proposal summary and, when complete,
   presents a new proposal with a new ID.

### Cancel

Cancel sends an AG-UI resume entry with status `cancelled`. The server marks the proposal
`CANCELLED`, returns a short acknowledgement, and performs no domain command.

### Expired proposal

An expired confirmation returns `PROPOSAL_EXPIRED`. The assistant asks the user to restate or retry
so all values can be validated against current state.

## 6. Failure and recovery

### Model unavailable or times out

- The run ends with `RUN_ERROR` and a stable code such as `ASSISTANT_UNAVAILABLE`.
- The composed user message remains visible with Retry.
- No proposal or domain mutation is assumed.
- Existing manual screens remain available.

### SSE connection is interrupted

- iOS marks the assistant response incomplete.
- A pre-confirmation run can be retried because it cannot mutate domain state.
- A confirmation retry reuses the same interrupt and confirmation IDs and is idempotent.

### Server validation rejects model output

- Invalid IDs, enum values, dates, or tool arguments are never passed to application use cases.
- The coordinator may give the model one bounded correction round.
- If still invalid, the run ends safely with `ASSISTANT_COULD_NOT_INTERPRET`.

### Refresh fails after a successful mutation

- The assistant says the change was saved.
- iOS shows its normal stale/offline notice and Retry Refresh action.
- It must not retry the mutation merely because refresh failed.

### Offline

- The composer explains that the assistant needs the Sankalpa service and model connection.
- The user can close chat and use existing manual capabilities.
- Conversational mutations are not queued. Existing session reliability behavior remains separate.

## 7. Accessibility and clarity

- Every streamed state has a text accessibility label; animation is never the only signal.
- Proposal cards expose fields in reading order and use native buttons.
- Confirm buttons name the action: **Log session** or **Declare Sankalpa**, not generic **Done**.
- VoiceOver announces when listening stops and when the transcript is ready to send.
- Dynamic Type, Reduce Motion, keyboard entry, and Voice Control are supported.
- A tool call is never shown as raw JSON to the user.
