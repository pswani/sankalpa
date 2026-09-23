<!--
Conversational voice functional requirements.
Functional requirements only. Do not add implementation, architecture, platform allocation, UI
layout, visual design, database schema, API, build, deployment, testing, or operational details.
-->

# Conversational voice

## Purpose

The user can speak naturally to Sankalpa to log a session or prepare a new Sankalpa. The user does
not need to remember command phrases or provide information in a fixed order.

The voice interaction helps the user clarify and review the requested action. It does not change
the meaning or rules of a Sankalpa. All requirements in [sankalpa.md](sankalpa.md) continue to
apply.

## Terms

- A **proposal** is the app's interpretation of a voice instruction. It has not been performed.
- A **draft** is a proposed new Sankalpa that has not been declared.
- A **pending session** is a session saved on the phone but not yet accepted by the Sankalpa
  service.

## Supported interactions

The first release supports two voice interactions:

1. Log one session for an existing Sankalpa.
2. Prepare, review, revise, and declare one new Sankalpa.

The user must be able to speak naturally throughout the interaction, including when answering a
question, revising a proposal, confirming an action, or cancelling the interaction. The user can
cancel at any time before the proposal is confirmed.

The app must present its questions, proposals, and results as text. It may also speak them.

The app must not substitute a different action when a request is unsupported. It must explain
that the requested action is not available through voice.

## Listening and transcription

The app listens only after the user starts a voice interaction. It must clearly indicate when it
is listening and allow the user to stop listening.

The app must show the recognized words as text. The user must be able to correct the recognized
words before confirming a proposal. After a correction, the app must interpret the corrected words
and update the proposal.

The app must not perform an action while the user is still speaking.

The app must not persist captured audio. It must discard the audio for an utterance after producing
the recognized words or when the user cancels listening.

## Interpretation and clarification

The app may infer information that is directly supported by the user's words. For example, it may
propose Physical Activity as the action type for a Gym Sankalpa.

Every inferred value must be included in the proposal shown to the user.

The app must ask for clarification when required information is missing or when it cannot form one
complete proposal from the user's words. It must not choose silently between multiple matching
Sankalpas, dates, times, or commitments.

The app must preserve information already agreed during the interaction. A later revision changes
only the values the user asks to change.

## Confirmation

Voice interpretation alone must not change the user's practice.

Before logging a session, the app must show:

- The Sankalpa title.
- The date and time the session will record.

Before declaring a Sankalpa, the app must show:

- Title.
- Description, when provided.
- Action type.
- Start date.
- Number of times per period.
- Period.
- Duration and derived end date, when a duration is provided.

The user must explicitly confirm the displayed proposal before the app performs the action. A
request to prepare or create a Sankalpa at the start of a conversation is not final confirmation;
confirmation occurs after the completed proposal is shown.

If the proposal changes after it is shown, the app must show the revised proposal and request
confirmation again.

## Logging a session

The app must resolve the spoken reference to exactly one existing Sankalpa. If no Sankalpa matches,
the app must say that it could not find one. If more than one Sankalpa matches, the app must ask the
user to choose.

When the user specifies a date and time, the proposal must use that date and time.

When the user says "today" without a time, the proposal must use the current date and time. The
exact date and time must be shown before confirmation.

When a time expression cannot be resolved to one date and time, the app must ask for clarification.

The app must apply the existing session eligibility rules before accepting the session. It must
report a refusal without changing the Sankalpa or performing another lifecycle action. In
particular, it must not begin or resume a Sankalpa in order to log a session.

## Preparing and declaring a Sankalpa

The app must maintain a draft while the user describes and revises a new Sankalpa.

The first release maintains at most one unfinished voice draft. If the user starts preparing
another Sankalpa while a draft exists, the app must offer to resume or discard the existing draft.
It must not discard the existing draft without the user's choice.

The app must obtain all information required to declare the Sankalpa:

- Title.
- Action type.
- Start date.
- Number of times per period.
- Period.

Description and duration remain optional.

The app must ask for required information that cannot be inferred from the user's words.

When the user describes a duration that is not a whole number of the chosen period, the app must
ask the user to choose a whole number of periods. It may suggest a conversion, but it must not
apply the conversion without confirmation.

Declaring a Sankalpa does not begin it. The voice interaction must not perform a lifecycle
transition as part of declaration.

## When the service is unavailable

The user must still be able to prepare, review, and revise a draft while the Sankalpa service is
unavailable.

A draft must remain a draft while the service is unavailable. The app must not describe it as
declared or queue it for automatic declaration.

The app must preserve the draft until the user declares or discards it. When the service becomes
available, the user must review and explicitly confirm the proposal before declaration.

When the service is unavailable, the app must accept an eligible session if the phone has enough
cached information to apply the existing session eligibility rules. After confirmation, it must
save the session as a pending session and state that it is waiting to be sent.

When the phone does not have enough cached information, the app must not accept the session. It
must explain that the Sankalpa cannot be verified while the service is unavailable.

Pending sessions must be sent when the service becomes available. If the service accepts a pending
session, it ceases to be pending. If the service refuses it, the app must remove it from the
practice shown on the phone and tell the user why it was refused.

## Result status

During a voice interaction, the app must distinguish among these outcomes:

- The service accepted the action.
- The session was saved on the phone and is waiting to be sent.
- The Sankalpa was saved as a draft and has not been declared.
- The action was not saved.

The app must not report that an action succeeded when it was only interpreted, proposed, or saved
as a draft.

## Outside the first release

The first release does not use voice to:

- Begin, pause, resume, complete, or stop a Sankalpa.
- Edit or delete a recorded session.
- Edit or delete an existing Sankalpa.
- Perform more than one action from a single confirmation.
- Answer general questions unrelated to the supported interactions.
- Listen continuously when the user has not started a voice interaction.
