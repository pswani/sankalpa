# Local and AWS backend operations

Use the same container image locally and on Lambda. The scripts do not contact AWS unless
`--target aws` is selected. `--plan` never contacts AWS or Docker and does not print secrets.

Reviewed October 17, 2026. Actual completed work and remaining blockers are recorded in
[implementation-review.md](../../docs/design/aws/implementation-review.md). For an existing
installation, validate/status first and resume incomplete steps; do not initialize a populated table.

## Prerequisites

- Java 21+, Maven, Python 3.11+, and Docker with Compose/buildx for container operations.
- An AWS credential profile, account ID, and permission to manage the selected Sankalpa resources.
- For the dedicated `sankalpa-deployer` user/profile, follow the complete
  [complete identity-setup script and guide](../../docs/design/aws/deployer-setup.md). Run its
  `--complete` command on your Mac; it handles browser administrator login, IAM setup, private
  credentials, local profile configuration, and access checks in one run.
- For AWS setup, the deployment identity needs the policy in `infra/deployer-policy.json`, with
  `REGION` and `ACCOUNT_ID` replaced by its actual values. It is an operator policy, not a Lambda
  runtime policy. Optional budget creation additionally requires the corresponding Budgets
  describe/create permissions and an explicitly configured notification address.

The scripts expect to be run from `backend/` in the examples below. Paths passed to `--env-file`
and `--sqlite` are relative to the invoking directory.

## Install tools and verify

```sh
./scripts/bootstrap-tools.sh
./scripts/verify-aws-local.sh
# Include a disposable ARM64 container deployment and lifecycle test:
./scripts/verify-aws-local.sh --container
```

The verification script starts an isolated, in-memory DynamoDB Local JVM on an available local
port, runs all backend tests including real SDK/HTTP adapter integration, runs operator tests,
and validates both CloudFormation templates. It removes only its own process and disposable test
tables. It never reads the practice SQLite database. To use an already-running local test server,
set `SANKALPA_TEST_DYNAMODB_ENDPOINT=http://127.0.0.1:PORT` explicitly.

`--container` additionally builds the Lambda-compatible image and verifies real HTTP mutations,
replacement, rollback, failed-release recovery, stop/start, and retained data after ordinary cleanup.
Its unique test project, volumes, private configuration, and image tags are removed afterward.

## Local deployment

```sh
cp .env.local.example .env.local
# Fill in a random local API token; keep the file private and ignored.
./scripts/backend deploy --target local --environment dev
./scripts/backend test --target local --environment dev
./scripts/backend status --target local --environment dev
./scripts/backend logs --target local --environment dev
./scripts/backend stop --target local --environment dev
./scripts/backend start --target local --environment dev
./scripts/backend rollback --target local --environment dev
./scripts/backend cleanup --target local --environment dev
```

The first deployment initializes an empty local DynamoDB practice if none exists. To preserve an
existing SQLite practice instead, start the Compose database first and import before deploying:

```sh
docker compose --project-name sankalpa-dev -f compose.yaml up -d dynamodb
./scripts/backend db import --target local --environment dev --sqlite /absolute/path/to/consistent-backup.db
./scripts/backend deploy --target local --environment dev
```

The SQLite source must already use the linked schema and contain a service UUID. Stop old practice
writes before cutover. The source is opened read-only and backed up consistently in memory.
Imports require an empty target and stay IMPORTING until structural and authoritative Java domain
validation both pass. An interrupted import must be inspected/discarded offline before retrying.

Local cleanup stops/removes managed containers but retains the data volume. The legacy
`scripts/deploy.sh` remains available for the original SQLite/JVM workflow. Replacement can stop
its recorded process only when its identity and listening port match this backend.

## AWS setup and data preparation

Create or edit `.env.prod` using the [configuration reference](../README.md#aws-deployment-settings),
including the account/profile, time zone, API token, and assistant settings. Keep an existing
configured file rather than replacing it. Configuration values are case-sensitive: use `true`,
`false`, and `openai`/`fake`. For `gpt-6-luna`, this backend requires reasoning effort `none`.

```sh
./scripts/backend setup --target aws --environment prod --plan
./scripts/backend setup --target aws --environment prod
```

`DEPLOY_CONCURRENCY=-1` uses the shared account concurrency pool and does not require a
quota increase. The existing account quota of 10 is sufficient for this configuration.
Positive values 1–10 explicitly reserve concurrency and require AWS's unreserved headroom.
`stop` sets a reservation of zero; `start` removes it again in shared mode. Neither operation
changes the Function URL or database. Concurrency and budgets are not dollar spending caps.

If `DEPLOY_BUDGET_EMAIL` is set, setup also accesses Budgets. The supplied deployer policy
does not grant those optional permissions. Use the administrator to create/verify the budget
and run `DEPLOY_BUDGET_EMAIL= ./scripts/backend setup --target aws --environment prod`
for routine setup after that.

Setup creates/updates the retained foundation stack, including table, ECR repository, execution
role, and logs. It does not initialize or replace your practice. Choose exactly one data operation:

```sh
# A new practice:
./scripts/backend db init --target aws --environment prod

# Or an existing practice, before any application stack exists:
./scripts/backend db import --target aws --environment prod --sqlite /absolute/path/to/consistent-backup.db

./scripts/backend db validate --target aws --environment prod
```

Build the Java package with `scripts/verify.sh` before using the domain validator if needed.
If a package is absent, the operator tool builds and verifies it automatically. Do not use a stale
package after editing the validation implementation.

## Preparing an older SQLite backup

An import error saying “Migrate/validate SQLite with the existing backend” means the source
needs the normal backend schema migration. Never add metadata markers by hand. Stop writes
to the old backend and create a consistent copy; do not run migration on the only backup.
From `backend/`, adjust these two paths and run:

```sh
.venv/bin/python - <<'PYTHON'
import sqlite3
from pathlib import Path
source = Path("../tmp/sankalpa.db").resolve()
target = Path("../tmp/sankalpa-aws-import.db").resolve()
if not source.is_file() or target.exists():
    raise SystemExit("Source must exist and migration destination must be new")
with sqlite3.connect(source.as_uri() + "?mode=ro", uri=True) as src, sqlite3.connect(target) as dst:
    src.backup(dst)
target.chmod(0o600)
print(target)
PYTHON

# Build/verify the current package first if needed; Java startup migrates and validates the copy.
SANKALPA_DB_URL="jdbc:sqlite:$(cd ../tmp && pwd)/sankalpa-aws-import.db" \
SANKALPA_PERSISTENCE=sqlite SANKALPA_DEPLOYMENT=local \
SANKALPA_TIMEZONE=America/Chicago SANKALPA_ASSISTANT_ENABLED=false \
SANKALPA_LLM_PROVIDER=fake \
java -jar target/sankalpa-backend-1.0.0-SNAPSHOT.jar \
  --spring.main.web-application-type=none --spring.config.import=

# Only for a NEW, empty AWS target without an application stack:
./scripts/backend db import --target aws --environment prod \
  --sqlite ../tmp/sankalpa-aws-import.db
./scripts/backend db validate --target aws --environment prod
```

Require successful Java startup/exit before importing. The migration preserves an existing
service UUID and creates a pre-migration backup for populated data. After successful import,
retain the original backup privately. Validation's `sessions` count includes all durable session
identities, including deleted ones, rather than only active practice-session rows.

## AWS releases and operation

```sh
./scripts/backend deploy --target aws --environment prod
./scripts/backend test --target aws --environment prod
./scripts/backend status --target aws --environment prod
./scripts/backend stop --target aws --environment prod
./scripts/backend start --target aws --environment prod
./scripts/backend rollback --target aws --environment prod
./scripts/backend cleanup --target aws --environment prod
```

Deploy verifies/builds/pushes the image, publishes a candidate, checks readiness/authentication and
a database-backed practice read, and promotes only after verification. The production URL remains
attached to the stable alias. A failed candidate leaves existing production pinned to its old version.
The first deployment has no previous release to preserve.

Stop/start preserve secrets with CloudFormation `UsePreviousValue`. A stopped deployment must be
explicitly restarted before deployment. Rollback republishes old code with the credentials from the
current environment file, avoiding silent restoration of a revoked credential.

Cleanup retains every alias target, managed published version, and referenced image. It does not
delete the production table. Images and data continue to incur storage charges while stopped.

## Staging

Generate a separate staging token; use fake provider mode initially. Do not copy production
data or secrets into staging. Complete staging acceptance before the first production release.


```sh
cp .env.staging.example .env.staging
# Fill in account/profile and a separate staging token.
./scripts/backend setup --target aws --environment staging
./scripts/backend db init --target aws --environment staging
./scripts/backend deploy --target aws --environment staging
./scripts/backend test --target aws --environment staging --mutations
./scripts/backend destroy --target aws --environment staging --yes
```

Mutation verification and destructive teardown are refused for production. Staging teardown checks
ownership tags before deleting its application stack and disposable retained resources. A restored
table is a separately retained recovery asset and must be handled explicitly.

## Parameters, secrets, and monitoring

Use `--env-file`, `--region`, `--profile`, `--environment`, `--image`, and repeated nonsecret `--set KEY=VALUE`
overrides. Explicit options override the selected file; supported process environment values can
also override it. Configuration is parsed as data; shell expressions are never executed.

`DEPLOY_RESOURCE_PREFIX` selects another owned namespace, for example `sankalpa-personal`.
Table, function, role, repository, and stack names derive from that prefix and the environment.
Use `--image sankalpa-backend:release-...` to deploy the same previously verified local image
locally or push it to the selected AWS repository without rebuilding.

Secrets are supplied through the ignored file, not command-line overrides. Lambda uses its role;
do not put AWS access keys in the image or iOS app. The runtime is outside a customer VPC.

Optional `DEPLOY_BUDGET_EMAIL` creates an account-wide monthly $5 budget with 80% and 100% actual
alerts if none exists. It does not impose a spending cap. Provider usage is separately billed.

## Recovery

Use DynamoDB point-in-time recovery in the Console to restore to a new table named
`sankalpa-prod-restore-<identifier>`. Validate its metadata and data before resuming service.
Apply ownership tags, deletion protection, PITR, and the operational TTL configuration to the
restored table; these are not supplied by the conditional external-table foundation resource.

Set `DEPLOY_RESTORED_TABLE_NAME` to the restored name and run `setup` to switch the foundation
output and runtime-role access. The original table is retained. Then redeploy the application with
the new foundation table output and verify identity/revision behavior. Keep the service stopped
during restoration; the current deployment requires an explicit start before candidate validation.
After role access switches, the old published code cannot write to the old table. Resume/promotion
can therefore produce a short read outage until the new candidate is serving.

Do not treat application rollback as data restore. Do not replay old pending client operations into
a restored practice without assessing records that were lost after the selected recovery point.

See [the design](../../docs/design/aws/design.md), [Console guide](../../docs/design/aws/aws-console-setup.md),
and [implementation verification](../../docs/design/aws/implementation-review.md).

## Current production access

Production is deployed at:

```text
https://xkf54pbp4oata4kxbnwsy3hk2a0rjwxl.lambda-url.us-east-1.on.aws/
```

Enter the base URL in the connected iPhone app's **Sankalpa service → Computer** field and
use the private `.env.prod` application token under **Authentication**. No AWS or provider
key belongs on the phone. See the [iPhone setup details](../../docs/design/aws/aws-console-setup.md#step-11--connect-the-iphone).

`/health/ready` returns HTTP 200 with an empty body; `/api/v1/capabilities` requires the token.
HTTPS, authentication, imported practice reads and real provider SSE have passed live checks.
Cold starts can take tens of seconds. The operator HTTPS probes use the AWS dependency's CA
bundle in addition to system trust; hostname and certificate verification remain required.
