# AWS Implementation and Verification

Date: implementation October 13, 2026; reviewed and reverified October 17, 2026.

Status: implementation/local verification, deployment identity, production foundation, data import
and production deployment are complete. Live REST and provider SSE checks pass. The user
confirmed the iPhone connection works on October 17, 2026. Advanced device workflows, cloud
recovery rehearsal and observed billing remain outstanding; the evidence below distinguishes
completed checks from those remaining activities.

## Current activity ledger — October 17, 2026

| Activity | Result and evidence |
|---|---|
| Administrator and deployer setup | Complete: `pswani1-admin` bootstrap and `sankalpa-deployer` profile in account `516246499367`; IAM setup and live reads passed |
| Production foundation | Complete: `sankalpa-prod-foundation` is `UPDATE_COMPLETE`; exact repository template and expected ownership tags verified |
| Production database | Complete: `sankalpa-prod` is ACTIVE, on-demand, PK/SK schema, no indexes/streams, deletion protection enabled, 35-day PITR, `ttlEpoch` enabled |
| Runtime role, ECR, logs | Audited against the template: scoped table/log permissions and Lambda trust, immutable AES-256 private images with Lambda retrieval policy, 14-day Standard logs |
| SQLite migration/import | Complete: consistent copy migrated through the normal Java backend; original `tmp/sankalpa.db` unchanged, existing service UUID preserved, exact imported document parity verified |
| Imported records | 2 sankalpas, 4 lifecycle transitions, 7 active sessions, 14 durable session identities total, 5 proposals; structural and authoritative Java domain validation passed |
| Budget | Created account-wide `Sankalpa Monthly`, $5/month; ACTUAL alerts at 80% and 100%, both matching the private configured email |
| Lambda quota | Existing pool of 10 used in shared mode; no increase required |
| Quota request | AWS rejected 104 because its API requires a value above the standard 1,000. Request `c787416843d84134bb5a2fd800be67bcLZRsfQwO` for 1,001 submitted; last observed CASE_OPENED. Superseded by the operator’s choice of shared concurrency |
| Local verification | 112 Java tests, 65 Python tests including the real local SDK migration test, both templates linted; all pass |
| Connected-client verification | 109 storage/client + 95 domain/application + 11 conversational tests pass; package tests do not establish physical-device acceptance |
| Container lifecycle | ARM64 build, real HTTP mutations/replay, replacement, rollback, failed replacement recovery, stop/start, cleanup/data retention all pass; disposable containers/volumes removed |
| Staging configuration | Prepared ignored mode-600 `.env.staging` with a separate random token, this account/deployer profile, fake provider, assistant disabled, no provider key |
| Release artifact | Deployed ARM64 digest `sha256:d9db004b9a62a1e5e1b1cda5c647a7d9889e8402735421f8314c953d5e16a4c2`; identical image in staging and production, no secrets bundled |
| Live application | Production stack complete; HTTPS readiness, anonymous/wrong-token refusal, authenticated practice reads, READY metadata, preserved UUID and domain validation pass |
| Provider streaming | Explicitly approved harmless production greeting: RUN_STARTED at 0.307 s, message at 3.758 s, RUN_FINISHED at 3.788 s. Business documents unchanged |
| Live lifecycle | Staging stop/start, second deployment, rollback, unused-version/image cleanup and domain validation passed; URL, identity and persisted data preserved |
| Staging teardown | Completed after acceptance; disposable stacks, function, table, repository and logs removed; private local staging configuration retained for future use |
| Physical iPhone | User confirmed the connection works on October 17, 2026; advanced correction/offline replay workflows are not yet separately verified |
| Billing observation | Actual charges over normal usage remain to be observed |

The budget is an alert, not a spending cap. The quota increase does not reserve paid compute;
no provisioned concurrency is configured. Production data was not changed by this review.

## Review corrections and execution

Reviewed the three operator/Console/review documents against the requirements, scripts,
templates, local execution and live AWS reads before continuing setup. Corrected stale
“no resources/no import” status, stack-level ownership tags, missing manual application
parameters, the implemented HTTPS fix, current-credential rollback behavior, optional budget
permissions, and the older-SQLite migration prerequisite. The adjacent deployer guide now
points to the migrated backup and warns against repeating an already-completed import.

The deploy command checks shared capacity or optional reservation headroom before building or
pushing an image. Initial verification confirmed the old reserved configuration refused the
account quota; the operator subsequently authorized shared concurrency as described below.

### Shared-concurrency decision and completed rollout

The operator explicitly chose shared concurrency instead of waiting for quota approval.
`DEPLOY_CONCURRENCY=-1` now omits the Lambda reservation; the existing account pool of 10
is sufficient. Stop still sets a zero reservation; start removes it. Positive reservations
remain optional. Regression tests cover shared startup, reservation removal, and positive
headroom checks. Backend verification passed 112 Java and 65 Python tests with real local
DynamoDB, plus template lint.

The former quota request is no longer a deployment prerequisite. If AWS approves it later,
the account-wide limit may change, but this configuration does not create a function reservation
or provisioned concurrency. The $5 budget remains an alert, not a spending cap.

Live staging creation exposed missing `logs:DescribeLogGroups` permission needed by
CloudFormation to resolve a log-group ARN. Added that read-only account discovery action to
the owned deployer policy. The failed staging stack retained an empty table, repository and
log group; recovery checks ownership and empty practice before recreating these staging-only
resources. Production data is unaffected.

Live staging HTTP/mutation and lifecycle acceptance, production deployment/read validation,
and approved provider streaming have passed. The user subsequently confirmed the
physical-iPhone connection works. Do not repeat production initialization/import. Live evidence is recorded below.

## Delivered implementation

| Area | Implementation |
|---|---|
| Persistence | AWS SDK v2 document store, DynamoDB repository ports, optimistic unit of work, atomic identity/projection/metadata transactions |
| Existing backend | Storage-specific transaction boundary; original SQLite/JDBC workflow retained |
| Assistant | Distributed thread lease with transactional fencing; provider-run daily/minute limits; confirmation and recovery bypass model quotas; timeout/disconnect cancellation |
| Authentication | Cloud startup rejects missing credentials; API bearer filter preserved; minimal readiness endpoint and cloud route boundary |
| Packaging | ARM64 Java 21 container with Lambda Web Adapter; Compose backend and persistent DynamoDB Local |
| Infrastructure | Retained foundation and staged application CloudFormation templates, stable Function URLs, scoped runtime role, sample deployment policy |
| Operator workflow | Setup, build, deploy, status, logs, stop/start, rollback, cleanup, staging teardown, initialization, import, validation, secret-free plans |
| Migration | Consistent read-only SQLite snapshot, identity/history/proposal preservation, projection validation, authoritative Java domain validation before READY |
| iOS | HTTPS port 443, legacy explicit-443 cache/journal compatibility, bounded retries only for reads and identity-bound exchanges |
| Documentation | Requirements, updated design/Console guide, environment examples, executable operator guide |

Use [the operator guide](../../../backend/scripts/README-aws.md) for executable commands.
The entry point is [`backend/scripts/backend`](../../../backend/scripts/backend).

## Design refinements made during implementation

- The three DynamoDB repository ports share `DynamoRepository`, reducing duplicate encoders and
  keeping one unit of work across practice and proposal operations.
- `UseCaseTransactions` allows both existing JDBC decorators and the DynamoDB boundary to reuse
  the same use-case interfaces. AWS types remain outside the domain/application layers.
- Provider quotas are checked immediately before the first model call of a run. They do not block
  pending-proposal recovery, persisted run replay, cancellation, or confirmation.
- `DEPLOY_RESOURCE_PREFIX` selects an owned namespace. Release state separates namespace,
  environment, target, account, and Region rather than sharing one environment-only file.
- A previously verified local image can be supplied with `--image`, preserving the application
  artifact while changing deployment configuration and repository location.
- The foundation accepts a validated restored-table pointer for recovery. Switching its runtime
  permissions and redeploying remains an explicit operator recovery operation.

## Review → fix → test findings

| Finding | Fix | Verification |
|---|---|---|
| JDBC-specific transaction wiring would prevent DynamoDB startup | Added generic transaction boundary, conditional repositories/configuration, datasource exclusions | Original backend suite and real DynamoDB Spring context tests |
| Cross-instance identity races could create duplicates or partial projections | Conditional atomic commits include durable metadata and identity/projection changes | Concurrent SDK replay, linked extension, tombstone, and confirmation tests |
| A lost thread lease could commit stale effects or release the new owner's lease | Commit includes lease fence; release compares exact ownership; contention detects ownership loss | Stale-owner test and real HTTP/SSE guard tests |
| Endpoint-wide/model quotas could block confirmation or recovery | Distributed provider budget gate at first model call; legacy local limiter skipped in DynamoDB mode | Quota/confirmation guard regression and SSE tests |
| Parsing SQLite timestamps through Python datetime lost nanosecond key ordering | Preserve all nine fractional digits in canonical keys | Nanosecond import and real SDK migration tests |
| Normalizing HTTPS display could make old caches and journals appear unrelated | Preserve explicit `:443` spellings while retaining service identity | Swift cached-practice/journal compatibility tests |
| Retrying every POST could duplicate declarations/lifecycle commands | Retry only GET, DELETE, and existing identity-bound requests on 429/503 | Swift gateway retry/declaration regression |
| Disabled assistant with OpenAI selected could still initialize a provider without a key | Disabled assistant uses the scripted adapter; OpenAI initialization requires enablement | Existing backend context regressions and container startup |
| Lambda log-group ARN could receive an extra wildcard suffix | Use the supplied ARN directly | CloudFormation lint |
| Stop/start could replace secret parameters with masked values | Preserve untouched parameters using `UsePreviousValue` | Operator NoEcho regression |
| Readiness could fail immediately on a startup connection reset | Retry bounded startup transport failures | Regression test and actual container deploy/stop/start |
| Cleanup could remove live/rollback images or another namespace's artifacts | Retain aliases/managed versions and image references; check ownership and namespace; skip unsafe image cleanup if other references cannot be established | Operator ownership tests and disposable container cleanup/data-retention run |
| Failed local replacement needed to restore the prior release | Restore the recorded image after failed readiness; leave release state unchanged | Actual exiting candidate restored the working container and practice data |
| SQLite snapshot connections were not explicitly closed | Close source/snapshot connections deterministically | Operator import suite without resource warnings |

The initial review used the design, code, tests and real local services. Subsequent live AWS
evidence is recorded separately below; this is not an independent external review.

## Verification evidence

### Backend

`backend/scripts/verify-aws-local.sh` passed against an isolated in-memory DynamoDB Local server.
It ran **112 backend tests with zero failures, errors, or skips**, including existing contracts,
architecture checks, new DynamoDB persistence/concurrency tests, Spring configuration,
authentication, assistant SSE, lease fencing, and proposal resolution.

The existing domain and HTTP behavior continue to pass with the SQLite/H2 test path. The
architecture checks now also reject AWS SDK dependencies in domain/application code.

### Operator and migration

Operator tests cover configuration parsing without shell execution, secret-free plans, production
mutation refusal, namespace validation, state separation, NoEcho preservation, ownership checks,
failed candidate promotion, rollback code selection, startup resets, item limits, and interrupted
imports. The real local SDK migration test preserves UUIDs, Unicode, revision, and nanoseconds.

The original operator suite comprises 19 tests; deployment quota/shared-start/HTTPS regressions add 5, and the
identity bootstrap adds 41, for 65 total, including the real SDK test when
`SANKALPA_TEST_DYNAMODB_ENDPOINT` is set. Default unit-only discovery explicitly skips that
integration test when no local server is configured.

### Container

`backend/scripts/verify_container.py` passed with the ARM64 Java 21 image, real Compose database,
and actual HTTP requests. It verified:

- Authenticated and anonymous capability behavior and database-backed reads.
- Declaration, Begin, session identity replay, linked extension replay, shared session reads,
  deletion replay, and permanent deletion identities.
- A second deployment and rollback with a stable service UUID.
- Stop/start preserving persisted data.
- An actually exiting replacement image followed by restoration of the prior working release.
- Cleanup preserving the volume, followed by restart with the same identity and records.
- Authoritative Java domain validation from the packaged executable jar.

The helper used a unique test namespace, random local ports, and a private generated token. Its
test containers, volume, network, release-state file, configuration, and image tags were removed.
It did not change the user's development or production practice.

Run the complete reproducible local/container check with:

```sh
cd backend
./scripts/bootstrap-tools.sh
./scripts/verify-aws-local.sh --container
```

### Connected iOS client

The Swift package suite passed: **109 storage/client tests, 95 domain/application tests, and
11 conversational XCTest cases**. It includes the HTTPS port/default constructor, normalized
address compatibility, and retry classification regressions.

This verifies package behavior, not a physical-device connection to a live AWS endpoint.

### Infrastructure and repository checks

Both CloudFormation templates passed `cfn-lint`. The setup command's `--plan` path was exercised
without AWS calls or secret output. Python syntax, shell syntax, local Markdown links, and Git
whitespace checks were checked before handoff.

## Remaining acceptance

Live setup, production REST access, authentication, database identity/parity and incremental
provider streaming have passed. Staging release and lifecycle results are recorded below.
The following checks still require separate operational/device work:

1. Cloud point-in-time restore-and-switch rehearsal, including protection, runtime permissions
   and metadata validation on the restored table. Import itself has already passed live.
2. Advanced physical-iPhone session correction, offline replay and pending-operation/service-identity
   behavior. Basic connection is user-confirmed; the broader workflow checks remain unverified.
3. Observation of actual billed duration, logs, storage and provider charges over real usage.

The user confirmation establishes basic device connectivity, not the full advanced device
acceptance matrix. No guaranteed monthly bill is claimed here.

## Practical limits

- Vow histories remain one DynamoDB item initially. Oversized records/transactions fail without
  partial changes. Real data near the item limit requires segmented history before migration.
- Numeric pagination and some contribution/count reads traverse matching records. The initial
  cost/performance target assumes a small personal dataset.
- Runtime configuration and credential rotation require publishing a release. Rollback uses
  current file-supplied credentials; the operator must retain that configuration locally.
- Application rollback does not undo cloud practice writes or restore a prior SQLite file.
- External restores need explicit protection/TTL/PITR/tag configuration and can require a short
  controlled outage while role and table configuration switch.
- Concurrency and budget alerts do not enforce a hard dollar cap.

## Live deployment evidence — shared concurrency

Production URL: https://xkf54pbp4oata4kxbnwsy3hk2a0rjwxl.lambda-url.us-east-1.on.aws/

Production service identity: `57f23afa-7d1e-4ce4-bc33-63ec9c00c340`.
The live imported document set exactly matched the migrated SQLite backup before the approved
assistant greeting; the greeting preserved business records. Provider operational usage/lease
records can change independently of practice records.

Shared mode is verified by the absence of `ReservedConcurrentExecutions` in the Lambda
concurrency response. The first live startup showed Java cold-start latency of tens of seconds.
A local Python CA-store failure initially prevented the operator's HTTPS probe despite curl and
the Lambda runtime succeeding. The probe now loads the AWS dependency CA bundle while retaining
certificate and hostname verification; an HTTPS regression test and all 65 Python tests pass.

Staging live mutation checks passed declaration/begin, session and linked-extension replay,
shared session reads, deletion replay and permanent tombstone behavior. Production verification
uses reads; the assistant greeting did not request or confirm mutations.

The user entered the production endpoint on the iPhone and confirmed it works. Detailed
session correction/offline replay checks, cloud PITR restore-and-switch rehearsal and elapsed
real billing observation remain separate operational acceptance activities.

Staging lifecycle acceptance completed against AWS: zero concurrency rejected new requests;
start removed the reservation and preserved data/identity; second deployment and rollback
preserved URL/identity; cleanup removed unused versions 1 and 2, retained aliased versions,
and passed the authoritative database validator. Disposable staging teardown then completed: both stacks, Lambda, table, repository and log
group were removed to avoid ongoing test-resource costs. Production remains serving version 1.
