# Sankalpa Backend

Spring Boot REST API for the Sankalpa bounded context. It follows the repository's DDD model and a
ports-and-adapters structure: the domain and application layers contain no Spring, HTTP, Jackson,
validation, or SQL dependencies; adapters provide REST, SQLite persistence, transactions, and time.

## Prerequisites

- Java 21 or later
- Maven 3.6.3 or later

## Build and verify

From this directory:

```bash
./scripts/verify.sh
```

The script runs a clean Maven build and all unit, architecture, persistence, and HTTP contract tests.
It keeps the raw Maven output and a compact, LLM-readable Markdown verdict under `logs/`, including
`logs/latest.log` and `logs/latest-summary.md`.

## Run

Copy `.env.example` to `.env`, then put the local time zone, API token, and provider credentials in
that file. `.env` is ignored by Git and is loaded when the service starts from this directory.

```bash
cp .env.example .env
mvn -Dmaven.repo.local=.m2/repository spring-boot:run
```

The [iOS app](../app/README.md) is a client of this service and holds no data of its own. It must
be pointed at the same time zone: both ends exchange offset-free wall-clock times, so a mismatch
makes the service reject sessions as being in the future and judge periods against the wrong day.

By default the API listens on `http://localhost:8080` and stores data in `data/sankalpa.db`. Override
the database with `SANKALPA_DB_URL` and the port with `PORT`. `SANKALPA_TIMEZONE` is required and
must be an IANA zone id shared with the client (for example, `America/Chicago`). Startup fails when
it is absent or invalid, avoiding silent interpretation of offset-free timestamps in the wrong zone.
For simulator-only development the API may run without authentication. Before exposing it to a
phone or another machine, terminate TLS at the service boundary and set a high-entropy
`SANKALPA_API_TOKEN`. When set, the same bearer token is required on every `/api/v1` endpoint.
The iOS settings screen stores it in the device Keychain. Put tokens and provider keys only in the
ignored `.env` file or the process environment, never in checked-in configuration.

## Conversational assistant

The optional assistant is disabled by default, so ordinary REST and manual app features do not
depend on a model provider. Its HTTP/SSE endpoint is `POST /api/v1/assistant/runs`, using the pinned
`ag-ui-sankalpa/1` profile advertised by `/api/v1/capabilities`.

For deterministic local use, enable the scripted adapter:

```bash
SANKALPA_ASSISTANT_ENABLED=true SANKALPA_LLM_PROVIDER=fake \
SANKALPA_TIMEZONE=America/Chicago mvn -Dmaven.repo.local=.m2/repository spring-boot:run
```

For OpenAI, the example environment selects `SANKALPA_LLM_MODEL=gpt-6-luna`. It also sets
`SANKALPA_LLM_REASONING_EFFORT=none`, which that model requires for tool calling through Chat
Completions. `SANKALPA_LLM_TIMEOUT` defaults to `PT30S` and
`SANKALPA_ASSISTANT_RUNS_PER_MINUTE` defaults to 30. The provider key remains server-side.
LangChain4j is isolated behind the application-owned `ConversationModel` port; it returns tool
requests but never executes them. All writes are persisted proposals and require an explicit,
replay-safe confirmation.

## Published API contract

- Swagger UI: `http://localhost:8080/swagger-ui.html`
- OpenAPI 3 JSON: `http://localhost:8080/v3/api-docs`

The contract is generated from the actual controllers and is asserted by `ApiContractTest` so an
endpoint cannot disappear unnoticed.

| Method | Path | Purpose |
|---|---|---|
| POST | `/api/v1/sankalpas` | Declare |
| GET | `/api/v1/sankalpas` | List |
| GET | `/api/v1/sankalpas/{id}` | Detail |
| POST | `/api/v1/sankalpas/{id}/begin` | Begin, optionally backdated |
| POST | `/api/v1/sankalpas/{id}/pause` | Pause now |
| POST | `/api/v1/sankalpas/{id}/resume` | Resume now |
| POST | `/api/v1/sankalpas/{id}/complete` | Complete now |
| POST | `/api/v1/sankalpas/{id}/stop` | Stop now |
| POST | `/api/v1/sankalpas/{id}/sessions` | Log a past session |
| GET | `/api/v1/sankalpas/{id}/sessions?page=0&size=50` | Paginated session history, newest first |
| GET | `/api/v1/sankalpas/{id}/lifecycle-history` | Lifecycle audit |
| GET | `/api/v1/sankalpas/{id}/period-outcomes` | Range-bounded derived outcomes |
| POST | `/api/v1/assistant/runs` | Pinned AG-UI JSON request and SSE response |

Business-rule failures use `application/problem+json` with a stable `code` property. Request enums
use uppercase names such as `MEDITATION`, `PHYSICAL_ACTIVITY`, `DAY`, and `SUCCESSFUL`.
`timesPerPeriod` is limited to 1–99; a supplied `periodCount` is limited to 1–3,650.

Session pages contain `content`, `page`, `size`, `totalElements`, and `totalPages`. Page numbering is
zero-based, the default size is 50, and the maximum size is 200. Optional `from` and `until` filters
must be supplied together. Offset-free timestamps are interpreted in `SANKALPA_TIMEZONE`.
Period-outcome queries may select at most 3,650 windows.

## Persistence

The normalized schema is in `src/main/resources/schema.sql`:

- `sankalpa` stores declaration, commitment, current lifecycle state, and optimistic version.
- `sankalpa_lifecycle_transition` stores ordered lifecycle audit facts using append-only writes.
- `practice_session` stores performed-session facts.

The derived end date and period outcomes are deliberately not stored. Production uses SQLite;
tests use an isolated in-memory H2 relational database plus domain/application fakes where suitable.
