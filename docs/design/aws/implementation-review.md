# AWS Implementation and Verification

Date: October 13, 2026.

Status: implementation and local verification complete. Live AWS deployment and physical-iPhone
acceptance remain deployment-dependent. No AWS resources were provisioned and no production
practice data was migrated during this work.

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

The review was performed locally against the design, code, tests, and real local services. It is
not represented as an independent external review or a successful live AWS deployment.

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

The final operator suite comprises 19 tests, including the real SDK test when
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

## Live acceptance still required

The operator must supply an AWS account/profile, actual credentials through that profile, and
an application token in the ignored environment file. Before production cutover:

1. Run setup and deploy in AWS staging, including account quota/IAM checks.
2. Verify Function URL HTTPS, actual Web Adapter streaming, IAM enforcement, version publication,
   alias promotion, stop/start, rollback, and cleanup through the live AWS services.
3. Rehearse import and point-in-time recovery, including restored table permissions and metadata.
4. Verify the connected physical iPhone and pending operation/service-identity behavior.
5. Measure billed duration, logs, storage, and provider usage against the cost assumptions.

These checks cannot be proven by local emulation or template lint. No live deployment result,
physical-device acceptance, or guaranteed monthly bill is claimed here.

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
