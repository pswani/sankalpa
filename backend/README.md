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

### Logs

The service logs to the console; `scripts/deploy.sh` captures it in `logs/server.log` and keeps
the replaced run's log as `logs/server.previous.log`. Each API change or refusal logs one line,
such as `POST /api/v1/sankalpas/{id}/pause -> 422 INVALID_LIFECYCLE_TRANSITION (8 ms)`, and each
assistant run logs its outcome. Successful reads log at DEBUG
(`LOGGING_LEVEL_COM_SANKALPA_ADAPTER_IN_WEB=DEBUG` to see them). Request bodies, practice text and
assistant transcripts are never logged. The iOS app logs sync and assistant failures to the unified
log under subsystem `com.sankalpa`, visible in Console.app.

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
| POST | `/api/v1/sankalpas/{id}/extensions` | Create a longer, independently completable linked vow |
| GET | `/api/v1/sankalpas/{id}/linked-series` | Ordered vows with their lifecycle histories |
| GET | `/api/v1/sessions` | Unique session facts with revision-bound cursor pagination |
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

## Linked extensions

The backend advertises `linkedSankalpaExtensions: 1`. Linked requests send
`Linked-Sankalpa-Version: 1` and the verified `Sankalpa-Service-Instance` UUID.
An extension body contains only `id` and `totalPeriodCount`; `Idempotency-Key` must match `id`.
The duration is the new total number of periods from the inherited start. Creation returns `201`;
an exact retry returns the same vow with `200` and `created: false`.

Sessions remain one fact with their original logging owner. Eligible members of the same series
share contributions; each vow retains its own lifecycle and completion. Delete through the
`loggingSankalpaId` returned with the fact. Unrelated vows retain the legacy contract. A legacy
client reading or changing linked vows receives `LINKED_SANKALPA_UPGRADE_REQUIRED`; exact session
identity replay and repeated deletion remain safe.

Linked session reads use `content`, `nextCursor`, and `hasMore`, with default size 100 and maximum
200. Both the canonical journal and per-vow cursor history accept optional paired date filters.
Responses carry `Sankalpa-Practice-Revision` as a decimal string. Send that revision on subsequent
refresh reads; a changed revision returns `READ_SNAPSHOT_CHANGED` and requires restarting the read.
Cursor continuation also checks revision, service instance, range, and target.

The backend and connected iOS client under `app/` implement linked extensions, shared session
contributions, and independent completion. Local-file support under `app2/` remains separate work. The full contract is in
[the linked extension design](../docs/design/linked-sankalpa-extensions/contracts.md).

## Persistence

`src/main/resources/schema.sql` retains the original idempotent bootstrap schema.
`LinkedSchemaMigration` upgrades fresh and existing databases before repositories serve requests:

- Schema version `linked_extensions_schema=1` and the practice revision live in `service_metadata`.
- SQLite upgrades rebuild the tables in a transaction, backfill self-root IDs and transition
  origins, validate the collection and identity ledger, check foreign keys, then commit.
- Before upgrading a populated file database, a consistent SQLite backup is saved beside it as
  `<database>.pre-linked-<UUID>.db`. Retain it for recovery; no live practice database is used by tests.
- Unknown versions and unmarked partial upgrades fail startup. H2 uses its DDL upgrade path for
  tests; its DDL is not rollback-atomic. A failed partial H2 upgrade also fails startup.
- Keep compatible code after creating linked records. Data rollback requires an explicit restore
  of the pre-upgrade backup; the backend never flattens linked vows automatically.

The normalized tables are:

- `sankalpa` stores declaration, commitment, current lifecycle state, and optimistic version.
- `sankalpa_lifecycle_transition` stores ordered lifecycle audit facts using append-only writes.
- `practice_session` stores performed-session facts.

The derived end date and period outcomes are deliberately not stored. The original local JVM
workflow uses SQLite; AWS Lambda uses DynamoDB. Tests cover both persistence adapters, with an
isolated H2 relational database and DynamoDB Local plus domain/application fakes where suitable.

## Low-cost local and AWS deployment

For a verified release of the current working tree, run `./scripts/release-aws` from `backend/`.
Use `./scripts/release-aws --full-ios` to include connected-app UI tests and its Release build.
The command tests the exact image it deploys, gates candidate promotion on identity/capabilities,
and verifies production afterward. See the [release workflow](scripts/README-aws.md#one-command-verified-aws-release).

The backend also supports DynamoDB persistence and a Lambda-compatible container image.
See [operator scripts](scripts/README-aws.md) for local build/deploy/test/stop and automated
AWS setup, staged release, rollback, cleanup, and data migration.
The [AWS design and Console guide](../docs/design/aws/README.md) describe the infrastructure.

Run `./scripts/bootstrap-tools.sh` once, then `./scripts/verify-aws-local.sh` to verify the
DynamoDB implementation against an isolated local server. AWS operations are explicit
(`--target aws`) and require your configured account/profile and ignored environment file.
`--plan` prints a secret-free plan without contacting AWS or Docker.

### Environment files and precedence

Run the following commands from `backend/`. Choose the file for the workflow you are using:

| Workflow | Configuration file | How it is loaded |
|---|---|---|
| Local JVM / SQLite (`mvn spring-boot:run`) | `.env` | Spring imports the file from its working directory. Start with `.env.example`. |
| Local container / DynamoDB (`scripts/backend --target local`) | `.env.local` | The operator script selects it. Start with `.env.local.example`. |
| AWS production (`scripts/backend --target aws --environment prod`) | `.env.prod` | The operator script selects it and passes runtime settings through CloudFormation into Lambda environment variables. |
| AWS staging (`scripts/backend --target aws --environment staging`) | `.env.staging` | The operator script selects it. Start with `.env.staging.example`. |

The operator script does not read `~/.env` or the local JVM `.env`. Copy a provider key into the
selected file when needed. `--env-file /absolute/path/to/file` selects another file. Supported
process environment variables override file values; explicit command options and nonsecret
`--set KEY=VALUE` overrides take precedence. Do not pass tokens or provider keys through `--set`.

Use `KEY=value` assignments, lowercase `true`/`false`, and lowercase `openai`/`fake`.
Full-line `#` comments and matching surrounding quotes are supported. The operator parser does
not execute shell commands, expand `${VARIABLE}` references, or accept `export KEY=value`.
Put comments on their own lines rather than after values. These files are ignored by Git and are
deployment inputs; they are not bundled into the container image. No Secrets Manager is required.

### AWS deployment settings

For a dedicated deployment identity, follow the [Sankalpa deployer setup guide](../docs/design/aws/deployer-setup.md).
It includes the administrator bootstrap script, policy attachment, access-key creation, named
profile configuration, and live permission checks. Use `DEPLOY_AWS_PROFILE=sankalpa-deployer`
after completing that setup.

Create or edit `.env.prod` with these settings. The values below are examples/defaults, not a copy
of any operator's credentials or personal configuration.

| Variable | Example / default | Purpose |
|---|---|---|
| `DEPLOY_ENVIRONMENT` | `prod` | Selects production; use `staging` in the staging file and command. |
| `DEPLOY_RESOURCE_PREFIX` | `sankalpa` | Owned resource namespace; the default production resources use `sankalpa-prod`. |
| `DEPLOY_REGION` | `us-east-1` | AWS Region for the stacks and data. |
| `DEPLOY_ACCOUNT_ID` | Your 12-digit account ID | The operator checks the authenticated AWS account before cloud operations. |
| `DEPLOY_AWS_PROFILE` | `sankalpa-deployer` | Local AWS credential profile created by complete setup. Keep AWS access keys in the AWS credential provider, not this file. |
| `DEPLOY_MEMORY` | `1024` | Lambda memory in MB; supported range 512–3072. |
| `DEPLOY_TIMEOUT` | `90` | Lambda invocation timeout in seconds; supported range 45–120. |
| `DEPLOY_CONCURRENCY` | `-1` | Shared account concurrency; optional positive reservation 1–10. Stop uses zero internally; start removes the reservation in shared mode. |
| `DEPLOY_ARCHITECTURE` | `arm64` | Image and Lambda architecture; `x86_64` is also supported. |
| `SANKALPA_TIMEZONE` | `America/Chicago` | Practice time zone; must match the iOS client. |
| `DEPLOY_BUDGET_EMAIL` | Empty | Optional opt-in to account-wide monthly $5 budget alerts. This is not a spending cap. |

The selected AWS profile must exist on the machine running deployment. For this repository, the
complete setup command below opens an administrator browser login and creates/reuses the
deployment user, policy, access key, local profile, and `.env.prod` profile selection automatically:

```sh
python3 scripts/setup_aws_deployer.py \
  --account-id 516246499367 --region us-east-1 \
  --admin-user pswani1-admin --complete
```

Run it on your Mac with Python 3.11+ and AWS CLI 2.32.0+. Select `pswani1-admin` in the browser;
no SSO session name, administrator access key, CloudShell upload, or manual deployer key copying
is needed. The [setup guide](../docs/design/aws/deployer-setup.md) explains checks, reruns, and
credential storage. It requires administrator IAM and local-browser-login permissions; it does
not import data or deploy the backend. Install the CLI if needed using the
[official installation instructions](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html).

### API authentication and assistant settings

| Variable | Suggested initial value | Where it is used |
|---|---|---|
| `SANKALPA_API_TOKEN` | A private random token, at least 32 characters | The backend checks `Authorization: Bearer <token>` on `/api/v1/` requests. AWS deployment rejects missing or placeholder tokens. |
| `SANKALPA_ASSISTANT_ENABLED` | `false` until AI is needed | Enables `POST /api/v1/assistant/runs`; ordinary REST operations remain available when disabled. |
| `SANKALPA_LLM_PROVIDER` | `openai` for real AI; `fake` for scripted development | Selects the model adapter when the assistant is enabled. |
| `SANKALPA_LLM_API_KEY` | Your provider key | Used server-side to authenticate OpenAI model requests. Keep the copied key; do not put it in the iOS app. |
| `SANKALPA_LLM_MODEL` | `gpt-6-luna` | Model ID passed to OpenAI when using the OpenAI adapter. |
| `SANKALPA_LLM_REASONING_EFFORT` | `none` for `gpt-6-luna` | Reasoning setting sent with each model request. This pairing is required for this adapter's Chat Completions tool calls. |
| `SANKALPA_LLM_TIMEOUT` | `PT20S` | ISO-8601 timeout per model request: 20 seconds. This is separate from the Lambda invocation timeout. |
| `SANKALPA_ASSISTANT_RUNS_PER_MINUTE` | `2` | DynamoDB-backed deployments share a fixed-window assistant model-run limit across instances. |
| `SANKALPA_ASSISTANT_RUNS_PER_DAY` | `20` | Shared model-run limit in DynamoDB-backed deployments; the day resets at midnight UTC. The SQLite workflow does not enforce this daily limit. |

Generate a backend token on your own machine with `openssl rand -hex 32`, then paste its output as
the value of `SANKALPA_API_TOKEN`. In the iOS app's service settings, enter that same token under
**Authentication → Bearer token**. The app stores it in the device Keychain. This token protects
your own API; the separate `SANKALPA_LLM_API_KEY` authenticates the backend's requests to OpenAI.

To enable the real assistant, set the following while preserving your existing token and key:

```dotenv
SANKALPA_ASSISTANT_ENABLED=true
SANKALPA_LLM_PROVIDER=openai
SANKALPA_LLM_MODEL=gpt-6-luna
SANKALPA_LLM_REASONING_EFFORT=none
SANKALPA_LLM_TIMEOUT=PT20S
SANKALPA_ASSISTANT_RUNS_PER_MINUTE=2
SANKALPA_ASSISTANT_RUNS_PER_DAY=20
```

OpenAI documents that GPT-6 Luna supports function calling through Chat Completions only with
`reasoning_effort=none`; see the [official model documentation](https://developers.openai.com/api/docs/models/gpt-6-luna).
Do not change the effort to `low` for this model with the current adapter. Changing models requires
checking their tool-calling and reasoning compatibility and verifying access with your account.

These quotas limit assistant runs that reach the model, not ordinary REST requests. In the
DynamoDB workflow, confirmation, cancellation, and persisted-result recovery do not consume a
model-run allowance. One run can make multiple model requests, so the quotas are not a hard token
or dollar limit. OpenAI provider usage is billed separately from AWS usage.

### Check and apply configuration

Preview the selected deployment without contacting AWS or Docker or printing secrets:

```sh
./scripts/backend deploy --target aws --environment prod --plan
```

The plan parses configuration and checks basic deployment settings. It does not verify the token,
authenticate AWS/OpenAI credentials, test model access, or check live AWS quotas. Actual deployment
also validates the backend token and requires an OpenAI key when the OpenAI assistant is enabled.

After the foundation exists and the practice has been imported or initialized, apply configuration:

```sh
./scripts/backend deploy --target aws --environment prod
./scripts/backend test --target aws --environment prod
```

Saving `.env.prod` does not update a running Lambda. Deployment publishes the new runtime settings
with a release. Stop/start preserve the deployed settings; they do not apply edited credentials.
The smoke test checks readiness, authentication, and practice reads; it does not make a paid model
request. Test the assistant separately after enabling it.

For an existing SQLite practice, follow the [migration instructions](scripts/README-aws.md#aws-setup-and-data-preparation)
before the first application deployment. Import requires an empty target; do not run `db init`
before `db import`.

### Historical-observance assistant acceptance

After the normal backend verification build, run the opt-in configured-provider check:

```sh
python3 backend/scripts/verify_assistant_history.py --provider-env backend/.env.prod
```

Run from the repository root. The script reads only model configuration from that file, starts a
throwaway local SQLite backend on a random port, and tests the screenshot conversation, confirmed
Begin correction, 30 daily records, replay, and a follow-up without an exact observance time. It
makes real model calls but no AWS practice requests or production writes. Synthetic SSE evidence
is retained in the temporary directory printed on success. See the
[repair design](../docs/design/conversational-batch-sessions/history-repair.md) for eligibility and
client negotiation. A new backend and native app are both needed to offer the v3 review card.
