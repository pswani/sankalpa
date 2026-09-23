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

```bash
SANKALPA_TIMEZONE=America/Chicago mvn -Dmaven.repo.local=.m2/repository spring-boot:run
```

The [iOS app](../app/README.md) is a client of this service and holds no data of its own. It must
be pointed at the same time zone: both ends exchange offset-free wall-clock times, so a mismatch
makes the service reject sessions as being in the future and judge periods against the wrong day.

By default the API listens on `http://localhost:8080` and stores data in `data/sankalpa.db`. Override
the database with `SANKALPA_DB_URL` and the port with `PORT`. `SANKALPA_TIMEZONE` is required and
must be an IANA zone id shared with the client (for example, `America/Chicago`). Startup fails when
it is absent or invalid, avoiding silent interpretation of offset-free timestamps in the wrong zone.
Authentication and TLS termination are intentionally not configured.

## Deploy locally

To verify, rebuild, replace the locally running backend, and wait for its API to become healthy:

```bash
./scripts/deploy.sh
```

The script preserves `data/sankalpa.db`, writes the running PID under `run/`, and writes service
output to `logs/server.log`. It uses the Mac's configured IANA time zone by default; set
`SANKALPA_TIMEZONE`, `SANKALPA_DB_URL`, or `PORT` to override the corresponding value. After a
successful standalone verification, `./scripts/deploy.sh --skip-verify` avoids running it twice.

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
