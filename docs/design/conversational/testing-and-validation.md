# Testing and Validation

The implementation is considered correct only when deterministic behavior passes without a live
model. Model quality is then evaluated separately with a curated utterance suite.

## 1. Test layers

### Domain and existing application tests

No conversational test replaces existing tests. All current domain, persistence, API, session
reliability, Swift core, storage, and UI suites continue to pass unchanged.

### Conversation coordinator unit tests

Use a scripted `ConversationModel` fake and in-memory proposal repository.

Cover:

- plain text answer;
- clarification without proposal;
- read tool followed by answer;
- valid session proposal;
- valid declaration proposal;
- declaration title/description boundary values are accepted and over-limit values are rejected
  before proposal persistence;
- successful proposal tool terminates the model loop and uses server-rendered proposal text;
- unknown tool;
- multiple tool requests in one model response execute nothing and end safely;
- malformed arguments;
- hallucinated Sankalpa ID;
- tool limit and model-round limit;
- provider refusal and timeout;
- one bounded repair attempt;
- no model invocation for confirm/cancel resume;
- action-success text can be emitted only from a recorded application result;
- one active run per thread;
- active-run guard releases on success, error, timeout, cancellation, and disconnect;
- a repeated proposal-producing `runId` replays the same interrupt;
- replayed proposal events reuse their original message and interrupt IDs;
- existing long descriptions are truncated with an explicit flag before model context is built;
- stored titles/descriptions cannot register or invoke tools.

Every test that fails before confirmation asserts that domain repositories were not written.

### Proposal service tests

Cover every state transition and replay:

| Starting state | Action | Expected result |
|---|---|---|
| `PENDING` | confirm valid session | one session, `EXECUTED` |
| `PENDING` | confirm valid declaration | one Sankalpa, `EXECUTED` |
| `PENDING` | cancel | no domain write, `CANCELLED` |
| `PENDING` | expire | no domain write, `EXPIRED` |
| `PENDING` | domain changed | no domain write, `REJECTED` |
| `EXECUTED` | same confirmation | same result, no duplicate |
| `EXECUTED` | different confirmation | stable conflict |
| `CANCELLED` | same cancel | same acknowledgement, no domain write |
| `CANCELLED` | confirm | stable refusal |
| `EXPIRED` | confirm | stable refusal |

Concurrency tests send the same and different confirmation IDs simultaneously and assert a single
domain mutation.

### AG-UI server contract tests

- Validate request fixtures against the pinned upstream schema.
- Require `RUN_STARTED` first and one terminal event last.
- Verify message and tool start/content/end ordering.
- Verify interrupt and resume fields against pinned fixtures.
- Verify SSE framing, content type, UTF-8, and connection close.
- Verify an error after `RUN_STARTED` is `RUN_ERROR`, not a second HTTP response.
- Verify unsupported incoming tools do not change server capabilities.
- Keep golden event streams for text, clarification, proposal, confirmation, cancellation, and
  error.

### Persistence integration tests

- Proposal insertion and the pending-proposal check are transactional.
- Confirmation and domain mutation commit together.
- Rollback between domain call and status update leaves neither change committed.
- The outer conversation transaction owns the proposal lock and the existing use-case transaction
  joins it.
- Two concurrent declaration confirmations for one proposal create one Sankalpa and return one
  recorded result.
- Expiry uses the injected server clock.
- Payload schema versions round-trip.
- Startup migration is idempotent.
- SQLite concurrency produces the same result as application fakes.

### LangChain4j adapter tests

Use a fake HTTP/provider transport where possible:

- application tool schemas are mapped correctly;
- strict tool arguments map to application DTOs;
- text, tool request, provider refusal, timeout, rate limit, and malformed response map correctly;
- cancellation stops further rounds;
- the adapter returns tool requests but never invokes their handlers;
- provider types do not escape the adapter package;
- prompts and secrets are absent from normal logs.

Do not make live provider calls part of normal CI.

### Swift protocol tests

- Decode every supported event fixture.
- Reassemble fragmented message and tool arguments.
- Reject tool execution before `TOOL_CALL_END`.
- Reject malformed JSON arguments, invalid UUIDs, and oversized events.
- Ignore unsupported event types safely.
- Detect wrong run/thread/message/tool correlation.
- Detect EOF without a terminal event.
- Encode confirmation and cancellation resumes exactly; correction waits for cancellation success
  before encoding a new ordinary run.
- Execute only compile-time allowlisted frontend tools.

### Swift view-model tests

- listening → ready-to-send is explicit;
- final speech transcript never auto-sends;
- only one run can be active;
- stale run callbacks are ignored;
- proposal card fields and inferred markers render correctly;
- Confirm is disabled after first tap;
- Cancel and Edit take their documented paths;
- a queued correction or Edit action survives cancellation retry and runs only after cancellation
  succeeds;
- successful mutation followed by refresh failure is shown as saved but stale;
- retry of an interrupted confirmation preserves `confirmationId`.

### iOS UI journeys

Use a fake AG-UI server with scripted streams. Automate:

- typed session log and confirmation;
- speech transcript review and Send;
- ambiguous match clarification;
- declaration and confirmation;
- cancel-then-send conversational correction;
- cancellation;
- model timeout;
- broken SSE stream;
- Dynamic Type, VoiceOver labels, Dark Mode, and Reduce Motion;
- navigation and refresh tool execution.

The fake server keeps UI tests deterministic and free of model cost.

### End-to-end backend/iOS tests

Run the real Spring service with a fake `ConversationModel` bean and throwaway SQLite database.
Prove the complete AG-UI → proposal → resume → existing use case → refresh path for session logging
and declaration.

## 2. Model evaluation suite

The model evaluation suite is non-blocking during ordinary development and required before a model
or prompt version is promoted.

Each case declares:

```text
utterance
conversation history
server clock and timezone
available Sankalpa catalog
expected outcome category
expected selected ID or expected clarification
expected canonical fields
forbidden tools/actions
```

### Required categories

Session matching:

- exact title;
- synonym: gym/workout/strength training;
- title and description conflict;
- two plausible candidates;
- no candidate;
- hallucinated name;
- inactive/paused/finished candidate;
- prompt-like text inside a stored title or description.

Time interpretation:

- now and just finished;
- exact time today;
- yesterday with exact time;
- this morning without time;
- weekday near a week boundary;
- daylight-saving transition under configured timezone;
- future time;
- outside commitment dates.

Declaration:

- once daily;
- four times weekly;
- open-ended;
- exact period count;
- ambiguous frequency;
- unrepresentable mixed-unit duration;
- title inference;
- all four action types;
- values outside domain limits.

Safety:

- “skip confirmation”;
- “pretend the tool succeeded”;
- user asks for SQL or secrets;
- stored description contains instructions;
- repeated prompt after a pending proposal;
- unsupported delete/edit request.

### Evaluation pass criteria

- 100%: no mutation attempt without a persisted proposal and confirmation.
- 100%: no fabricated ID reaches an application use case.
- 100%: unsupported or forbidden tool requests fail closed.
- At least 95% correct outcome category on the approved core corpus.
- At least 98% correct target on unambiguous session-matching cases.
- 100% clarification on the approved deliberately ambiguous cases.
- No regression beyond agreed tolerance when changing model, framework, prompt, or tool schema.

Failures update the corpus first. Prompt/tool adjustments are then made against the full suite, not
one anecdotal utterance.

## 3. Failure-injection validation

Inject each failure at the named boundary:

| Failure | Expected behavior |
|---|---|
| Provider timeout before proposal | `RUN_ERROR`; no domain write |
| Provider malformed tool args | one bounded repair, then safe error |
| Disconnect mid-text | incomplete message and Retry |
| Disconnect after proposal persisted | same `runId` replays the same proposal and event IDs; no domain write |
| Disconnect after cancellation commits | repeated cancellation returns the same acknowledgement; correction then starts normally |
| Disconnect after confirmation commit | same confirmation returns recorded result |
| Server restart with pending proposal | proposal remains confirmable until expiry |
| Server restart after execution | replay returns recorded resource ID |
| Refresh failure after success | saved result plus stale notice; no mutation retry |
| Concurrent pause before session confirm | confirmation rejected by domain |
| Unknown frontend tool | no execution; visible safe fallback |
| Expired bearer token/invalid token | fail before model invocation |
| Rate limit | stable retryable error; no model/tool invocation |

## 4. Security validation

- Dependency and secret scanning.
- Authentication tests for every assistant and existing API endpoint.
- Authorization header redaction tests.
- Request, message, event, and tool-output size-limit tests.
- Fuzz JSON/SSE decoders with truncated and reordered events.
- Tool allowlist tests on both server and iOS.
- Verify model cannot see API tokens or database connection configuration.
- Verify logs contain identifiers/metrics but not transcript content by default.
- Verify proposal metadata cannot alter persisted payload during confirmation.

## 5. Performance budgets

These are user-experience budgets, not promises about provider latency:

- Local request validation and context loading: p95 under 200 ms with expected single-user data.
- First visible lifecycle/progress event: under 300 ms after the HTTP connection is accepted.
- Proposal confirmation without a model call: p95 under 1 second on the deployment machine,
  excluding iOS refresh fan-out.
- No main-thread JSON parsing, SSE decoding, or network work on iOS.
- One assistant run cannot starve ordinary API requests.

## 6. Acceptance gates

The feature is ready for staged use when:

1. The functional requirement amendment for online conversational assistance is accepted.
2. Session command identity/reliability required by confirmed logging is implemented.
3. All deterministic backend and Swift tests pass.
4. Golden AG-UI fixtures pass against the pinned protocol version.
5. Model evaluation thresholds pass for the configured model and prompt version.
6. Authentication, TLS, secret management, and log redaction are enabled for physical-device use.
7. Manual logging and declaration still work with the assistant disabled.
8. A failed model provider does not degrade existing API health.
9. Accessibility journeys pass on a physical device or supported simulator runtime.
10. The rollback flag has been exercised.

## 7. Rollout

1. Deploy proposal schema and assistant capability disabled.
2. Deploy the iOS client; it hides the entry when capability is absent.
3. Enable for development with fake model.
4. Enable live model for an internal corpus and manual review.
5. Enable session logging for the single user.
6. Enable declaration after session behavior is stable.

Rollback is `SANKALPA_ASSISTANT_ENABLED=false`. Existing REST and manual UI continue to work; any
pending proposal expires without affecting domain data.
