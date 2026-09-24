# Conversational Requirements and Traceability

These are the proposed functional requirements implied by this design. They are kept here until
accepted into the product requirements; this document does not silently amend
`docs/requirements/sankalpa.md`.

## Proposed requirements

| ID | Requirement |
|---|---|
| CR-01 | The user can send a typed natural-language message to Sankalpa Assistant. |
| CR-02 | The user can dictate into the same editable composer; transcription never hides whether the message has been sent. |
| CR-03 | The assistant can answer bounded questions about the user's server-held Sankalpas. |
| CR-04 | The assistant can propose logging a session against an existing Sankalpa. |
| CR-05 | The assistant can propose declaring a new Sankalpa using fields in the current domain. |
| CR-06 | No session or Sankalpa is created until the user sees canonical values and explicitly confirms. |
| CR-07 | The user can cancel a pending proposal or correct it through the native edit form or a cancel-then-send conversational flow, without the pending proposal changing domain state. |
| CR-08 | The assistant asks for clarification when a required value or target cannot be determined safely. |
| CR-09 | Relative dates and times use the service's configured clock and timezone. |
| CR-10 | A conversational command is subject to exactly the same domain rules as its manual equivalent. |
| CR-11 | Confirmation is replay-safe and cannot create a duplicate after retry, timeout, or lost response. |
| CR-12 | The service revalidates current domain state at confirmation time. |
| CR-13 | A successful conversational mutation is followed by an authoritative client refresh. |
| CR-14 | Model, transport, or refresh failure is visible and never implies an unconfirmed action succeeded. |
| CR-15 | The manual UI remains available when the assistant or model provider is unavailable. |
| CR-16 | The assistant requires an online service connection; conversational commands are not queued offline. |
| CR-17 | Microphone audio remains on device; only the user-reviewed transcript is sent to the service. |
| CR-18 | The application clearly discloses that transcript text and bounded practice context are sent to the configured model provider. |
| CR-19 | Unsupported actions are explained and not approximated with a different mutation. |
| CR-20 | The assistant is usable with typing alone and supports the app's accessibility requirements. |

## Scope decisions

- CR-04 and CR-05 are the only conversational write capabilities in v1.
- A new Sankalpa is declared in `NOT_STARTED`, exactly like the existing declaration path. The
  assistant does not automatically Begin it. The result screen may navigate to the normal Begin
  action.
- Existing lifecycle commands remain manual until separately added to these requirements.
- Existing session reliability rules apply to CR-04. Because every conversational log requires
  confirmation, that confirmation also satisfies the rapid-repeat confirmation rule; v1 does not
  add a second assistant-specific warning.
- The current requirements do not permit editing or deleting a Sankalpa, so conversation cannot do
  either.

## Traceability

| Requirement | Design location | Primary validation |
|---|---|---|
| CR-01–02 | [user-journeys.md](user-journeys.md), journeys 1A–1B | Swift view-model and UI tests |
| CR-03 | [architecture.md](architecture.md), context and read tools | Coordinator and model-eval tests |
| CR-04 | [user-journeys.md](user-journeys.md), section 2 | Proposal integration and E2E tests |
| CR-05 | [user-journeys.md](user-journeys.md), section 3 | Declaration proposal and E2E tests |
| CR-06–08 | [contracts.md](contracts.md), interrupt/resume contract | AG-UI and proposal state tests |
| CR-09–10 | [architecture.md](architecture.md), time and matching | Domain, clock, and evaluation tests |
| CR-11–12 | [architecture.md](architecture.md), confirmation transaction | Replay and concurrency tests |
| CR-13–16 | [user-journeys.md](user-journeys.md), failure and recovery | Failure-injection and UI tests |
| CR-17–18 | [architecture.md](architecture.md), speech/privacy | Permission, disclosure, and log tests |
| CR-19 | [user-journeys.md](user-journeys.md), unsupported action | Coordinator and model-eval tests |
| CR-20 | [user-journeys.md](user-journeys.md), accessibility | UI accessibility journeys |
