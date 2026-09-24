# Contracts

This document fixes the application-level contract. During implementation, the selected AG-UI
release must be pinned and the JSON examples reconciled with that release's generated schema.
Upstream `main` is not a runtime dependency.

## 1. HTTP transport

```http
POST /api/v1/assistant/runs
Authorization: Bearer <single-user-token>
Content-Type: application/json
Accept: text/event-stream
```

Success begins an SSE stream. Authentication, unsupported media type, and an invalid top-level
request may fail as ordinary HTTP before `RUN_STARTED`. Once `RUN_STARTED` is emitted, failures are
represented by `RUN_ERROR` and the stream closes.

No WebSocket endpoint is needed.

## 2. Supported `RunAgentInput` profile

The client sends the canonical AG-UI fields:

| Field | Rule |
|---|---|
| `threadId` | Client-generated UUID, stable for the local conversation |
| `runId` | New client-generated UUID for each logical run; reuse only when retrying that run after an uncertain transport outcome |
| `parentRunId` | Optional; most recent completed run when known |
| `state` | Empty object in v1 |
| `messages` | Bounded AG-UI messages, latest user message last |
| `tools` | The fixed safe frontend tool definitions supported by this app version |
| `context` | Empty; the server obtains authoritative context itself |
| `forwardedProps` | Empty object in v1 |
| `resume` | Present only to resolve or cancel an open interrupt |

The server rejects malformed UUIDs, duplicate message IDs, unsupported roles, oversized content,
and a resume that does not refer to a persisted pending proposal owned by the same thread. If the
thread has a pending proposal, an ordinary input without a matching resume is rejected; the client
must confirm or cancel first.

## 3. Supported outbound events

| Event | Use |
|---|---|
| `RUN_STARTED` | Mandatory first event |
| `TEXT_MESSAGE_START` | Begin one assistant message |
| `TEXT_MESSAGE_CONTENT` | One or more non-empty deltas |
| `TEXT_MESSAGE_END` | Complete the message |
| `TOOL_CALL_START` | Begin one safe frontend tool request |
| `TOOL_CALL_ARGS` | JSON argument fragments |
| `TOOL_CALL_END` | Complete the frontend tool request |
| `RUN_FINISHED` | Success or an interrupt awaiting user input |
| `RUN_ERROR` | Terminal failure |

`RUN_STARTED` and exactly one of `RUN_FINISHED` or `RUN_ERROR` are required. Message and tool IDs
must be unique within a thread and correlated across their start/content/end sequence.

The client must ignore unsupported event types without crashing but records a protocol diagnostic.
It must never execute an unsupported tool merely because an event is syntactically valid.

## 4. Proposal interrupt

A proposal is represented once: as an AG-UI interrupt in `RUN_FINISHED.outcome`. It is not also
sent as a `present_*` tool call.

Illustrative session proposal:

```json
{
  "type": "RUN_FINISHED",
  "threadId": "1389ea72-38f4-4fb0-a567-51a00bf1a6f4",
  "runId": "41b7ccfc-b1f1-46b0-83b3-18838b005d62",
  "outcome": {
    "type": "interrupt",
    "interrupts": [
      {
        "id": "63331d40-26c0-4e89-821b-2c4f5f8c16e0",
        "reason": "confirmation",
        "message": "Confirm this session before it is logged.",
        "expiresAt": "2026-09-23T15:45:00-05:00",
        "responseSchema": {
          "type": "object",
          "properties": {
            "decision": { "type": "string", "enum": ["confirm"] },
            "confirmationId": {
              "type": "string",
              "format": "uuid"
            }
          },
          "required": ["decision", "confirmationId"],
          "additionalProperties": false
        },
        "metadata": {
          "proposalType": "LOG_SESSION",
          "proposalVersion": 1,
          "sankalpaId": "2de4bf30-a953-4651-b5e6-af2f8a634c2c",
          "sankalpaTitle": "Gym four times a week",
          "occurredAt": "2026-09-23T08:15:00"
        }
      }
    ]
  }
}
```

The metadata is presentation data derived from the persisted canonical proposal. It is not an
authorization token and cannot be altered to change execution.

## 5. Resume contracts

### Confirm

```json
{
  "threadId": "1389ea72-38f4-4fb0-a567-51a00bf1a6f4",
  "runId": "0b461b72-a356-4cd1-86c2-e04629d9ff4d",
  "parentRunId": "41b7ccfc-b1f1-46b0-83b3-18838b005d62",
  "state": {},
  "messages": [],
  "tools": [
    {
      "name": "refresh_practice",
      "description": "Refresh the authoritative Sankalpa practice after a saved change.",
      "parameters": {
        "type": "object",
        "properties": {
          "reason": {
            "type": "string",
            "enum": ["SESSION_LOGGED", "SANKALPA_DECLARED"]
          }
        },
        "required": ["reason"],
        "additionalProperties": false
      }
    }
  ],
  "context": [],
  "forwardedProps": {},
  "resume": [
    {
      "interruptId": "63331d40-26c0-4e89-821b-2c4f5f8c16e0",
      "status": "resolved",
      "payload": {
        "decision": "confirm",
        "confirmationId": "b6ff5b73-9681-41ec-9889-d00d1c26ed18"
      }
    }
  ]
}
```

### Cancel

```json
{
  "interruptId": "63331d40-26c0-4e89-821b-2c4f5f8c16e0",
  "status": "cancelled"
}
```

### Correct conversationally

Correction does not add another resume payload or proposal state. While a proposal is open, iOS:

1. retains the user's correction locally;
2. sends the ordinary cancellation resume shown above;
3. retries that same cancellation if its response is lost; and
4. only after cancellation succeeds, starts a new run with the correction as the latest user
   message and the prior canonical proposal summary in bounded history.

Only one interrupt is resolved per run in v1. The server rejects mixed or duplicate resume entries.
Confirmation requires the exact payload schema above. Cancellation has no payload.

## 6. Internal model tools

Internal tools are not AG-UI frontend tools. Their schemas are constructed by the server and sent
only to the configured model.

### `get_sankalpa`

```json
{
  "type": "object",
  "properties": {
    "sankalpaId": { "type": "string", "format": "uuid" }
  },
  "required": ["sankalpaId"],
  "additionalProperties": false
}
```

Returns the bounded current detail or `SANKALPA_NOT_FOUND`.

The result is a typed DTO containing the fields from the server catalog. `description` is at most
2,000 characters and `descriptionTruncated` states whether more stored text exists.

### `get_recent_sessions`

```json
{
  "type": "object",
  "properties": {
    "sankalpaId": { "type": "string", "format": "uuid" },
    "from": { "type": "string", "format": "date" },
    "until": { "type": "string", "format": "date" },
    "limit": { "type": "integer", "minimum": 1, "maximum": 50 }
  },
  "required": ["sankalpaId", "from", "until", "limit"],
  "additionalProperties": false
}
```

Returns at most `limit` items containing `sessionId` and `occurredAt`, plus `truncated`, which is
true when more matching sessions exist. It never returns raw persistence objects.

### `get_period_summary`

```json
{
  "type": "object",
  "properties": {
    "sankalpaId": { "type": "string", "format": "uuid" },
    "from": { "type": "string", "format": "date" },
    "until": { "type": "string", "format": "date" },
    "limit": { "type": "integer", "minimum": 1, "maximum": 50 }
  },
  "required": ["sankalpaId", "from", "until", "limit"],
  "additionalProperties": false
}
```

Returns at most `limit` period entries containing `start`, `end`, `required`, `performed`, `missed`,
and `standing`, plus `truncated`. The tool rejects an invalid range and does not silently expand it.

### `propose_log_session`

```json
{
  "type": "object",
  "properties": {
    "sankalpaId": { "type": "string", "format": "uuid" },
    "occurredAt": {
      "type": "string",
      "pattern": "^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}$",
      "description": "Offset-free local date-time interpreted in SANKALPA_TIMEZONE"
    },
    "userSummary": { "type": "string", "maxLength": 200 },
    "alternativeSankalpaIds": {
      "type": "array",
      "items": { "type": "string", "format": "uuid" },
      "maxItems": 3
    }
  },
  "required": ["sankalpaId", "occurredAt", "userSummary", "alternativeSankalpaIds"],
  "additionalProperties": false
}
```

The handler requires the chosen ID to be in current context and validates the timestamp through a
side-effect-free domain eligibility method shared with `Sankalpa.logSession`. It refuses to create
a proposal when alternatives indicate unresolved ambiguity.

### `propose_declare_sankalpa`

```json
{
  "type": "object",
  "properties": {
    "title": { "type": "string", "minLength": 1, "maxLength": 200 },
    "description": { "type": "string", "maxLength": 2000 },
    "actionType": {
      "type": "string",
      "enum": ["MEDITATION", "PRANAYAMA", "PHYSICAL_ACTIVITY", "OBSERVANCE"]
    },
    "startDate": { "type": "string", "format": "date" },
    "periodUnit": {
      "type": "string",
      "enum": ["DAY", "WEEK", "MONTH", "YEAR"]
    },
    "timesPerPeriod": { "type": "integer", "minimum": 1, "maximum": 99 },
    "periodCount": {
      "anyOf": [
        { "type": "integer", "minimum": 1, "maximum": 3650 },
        { "type": "null" }
      ]
    },
    "inferredFields": {
      "type": "array",
      "items": {
        "type": "string",
        "enum": ["title", "description", "actionType", "startDate", "periodUnit", "timesPerPeriod", "periodCount"]
      }
    }
  },
  "required": [
    "title", "description", "actionType", "startDate", "periodUnit",
    "timesPerPeriod", "periodCount", "inferredFields"
  ],
  "additionalProperties": false
}
```

The handler reconstructs the current domain value objects and derives the end date. The proposal
records which fields were inferred so the confirmation card can label them without exposing model
reasoning.

## 7. Frontend tools

Frontend tools are declared by iOS in `RunAgentInput.tools`; the server intersects that list with
its own allowlist. If the installed client does not advertise a tool, the server falls back to a
text response.

`refresh_practice` is emitted only by deterministic post-mutation coordinator code. The model may
request one of `navigate_to_sankalpa` or `open_sankalpa_list` as its sole tool request for a turn.
The coordinator validates the request against current context before emitting any AG-UI event.

### `refresh_practice`

```json
{
  "type": "object",
  "properties": {
    "reason": { "type": "string", "enum": ["SESSION_LOGGED", "SANKALPA_DECLARED"] }
  },
  "required": ["reason"],
  "additionalProperties": false
}
```

### `navigate_to_sankalpa`

```json
{
  "type": "object",
  "properties": {
    "sankalpaId": { "type": "string", "format": "uuid" }
  },
  "required": ["sankalpaId"],
  "additionalProperties": false
}
```

### `open_sankalpa_list`

```json
{
  "type": "object",
  "properties": {},
  "required": [],
  "additionalProperties": false
}
```

Frontend tools never carry domain objects to merge into local state. `refresh_practice` obtains the
authoritative objects through the existing API client.

## 8. Event ordering for successful confirmation

```text
RUN_STARTED
TEXT_MESSAGE_START
TEXT_MESSAGE_CONTENT  "Your session was logged."
TEXT_MESSAGE_END
TOOL_CALL_START       refresh_practice
TOOL_CALL_ARGS
TOOL_CALL_END
TOOL_CALL_START       navigate_to_sankalpa
TOOL_CALL_ARGS
TOOL_CALL_END
RUN_FINISHED          outcome=success
```

iOS executes complete allowlisted tool calls in stream order. A navigation waits for an attempted
refresh. If refresh fails, navigation may still open cached detail while the normal stale-state
notice remains visible.

iOS records a bounded local `ToolMessage` result for each frontend tool. The result is included in
later conversation history but does not automatically continue the run or ask the model to repair
UI behavior.

## 9. Stable error codes

| Code | Meaning | Retry |
|---|---|---|
| `ASSISTANT_DISABLED` | Feature disabled by server configuration | No, use manual UI |
| `ASSISTANT_BUSY` | Another run owns this thread | After that run ends |
| `ASSISTANT_UNAVAILABLE` | Provider/network/timeout failure | Yes |
| `ASSISTANT_LIMIT_REACHED` | Tool/model/context bound exceeded | Restate more simply |
| `ASSISTANT_COULD_NOT_INTERPRET` | Model output was invalid or unsupported | Yes or manual UI |
| `AGUI_PROTOCOL_ERROR` | Malformed or inconsistent event/input contract | After client/server correction |
| `PROPOSAL_NOT_FOUND` | Unknown proposal/interrupt | Restate request |
| `PROPOSAL_EXPIRED` | Confirmation arrived after expiry | Restate request |
| `PROPOSAL_ALREADY_RESOLVED` | A different action targets an already cancelled or executed proposal | Refresh conversation |
| `PROPOSAL_REJECTED` | Domain changed or command was refused | Follow domain explanation |

Existing domain error codes remain intact and may be included as structured metadata behind
`PROPOSAL_REJECTED`. User-facing language comes from the app's established error mapping, not raw
provider output.

## 10. Compatibility

- Assistant capability and pinned AG-UI profile version are published by `/api/v1/capabilities`.
- iOS hides/disables chat when the capability is absent.
- Additive frontend tools are optional; the server checks what the client advertises.
- Proposal payloads are versioned. Unsupported versions are refused, never guessed.
- The existing REST endpoints remain the public domain contract and manual fallback.
