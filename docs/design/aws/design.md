# Sankalpa: Low-Cost AWS Deployment Design

Status: design implemented October 13, 2026; see the implementation review for local evidence and live AWS acceptance boundaries.

See the [requirements](../../requirements/aws.md) and
[AWS Console setup guide](aws-console-setup.md).

## 1. Scope and architecture

Deploy the existing Java 21/Spring Boot backend as one Lambda function. Preserve the REST
endpoints and optional assistant streaming endpoint.

```text
iOS app
   │ HTTPS + application bearer token
   ▼
AWS Lambda Function URL attached to the prod alias
   ▼
Lambda Web Adapter → Spring Boot
   ├── DynamoDB: practice records, identities, proposals, operational guards
   ├── CloudWatch: operational logs
   └── Optional external model provider
```

The AWS-generated hostname provides trusted HTTPS. No custom DNS, API Gateway, RDS,
Secrets Manager, NAT gateway, or customer VPC is needed initially. The function can access
DynamoDB and an external model provider without the private-network egress arrangement
required by the earlier RDS proposal.

Retain the single-user model: the bearer credential authorizes access to the whole practice.
Multi-user ownership and authorization are separate work. The connected iOS client under
`app/` is in scope; the local-file client under `app2/` is not.

## 2. Resources and ownership

Use `us-east-1` initially, with these CloudFormation stacks per environment:

| Stack | Resources | Lifecycle |
|---|---|---|
| `sankalpa-prod-foundation` | DynamoDB table, private ECR repository, execution role, log group | Retained across application replacement |
| `sankalpa-prod-app` | Lambda function, versions, aliases, Function URLs, URL permissions | Updated for releases |

Use equivalent staging names. Foundation outputs are passed as application parameters rather
than relying on implicit resource discovery. The foundation must not depend on the app stack.

| Resource | Production name |
|---|---|
| DynamoDB table | `sankalpa-prod` |
| ECR repository | `sankalpa-prod` |
| Lambda function | `sankalpa-prod` |
| Execution role | `sankalpa-prod-runtime` |
| Log group | `/aws/lambda/sankalpa-prod` |
| Production alias | `prod` |
| Validation alias | `candidate` |

Apply `Project=Sankalpa`, `Environment=prod`, and `ManagedBy=CloudFormation` tags.
Enable production table deletion protection and `DeletionPolicy: Retain` and
`UpdateReplacePolicy: Retain`. Preserve the ECR repository needed by retained releases.
Document any retained resources after stack deletion; retention does not eliminate their bill.

Before any mutation, the deployment tool verifies the account, Region, environment, resource
names, and ownership. It must not adopt or delete unrelated resources merely because their
names or ports resemble Sankalpa.

## 3. Packaging and runtime

Build one Linux container containing Java 21, the verified Spring Boot application, and a
pinned AWS Lambda Web Adapter release. Use a multi-stage build; exclude build caches,
development data, and secret-bearing environment files from the runtime image.

Record the source revision, image digest, target architecture, configuration fingerprint
without secret values, and release identifier. Build ARM64 initially; the deployed image
and Lambda architecture must agree.

| Setting | Initial value |
|---|---|
| Memory | 1,024 MB |
| Timeout | 90 seconds |
| Temporary storage | 512 MB |
| Reserved concurrency | 2 |
| Provisioned concurrency | None |
| VPC attachment | None |
| Internal server port | 8080 |

Reserved concurrency bounds simultaneous work but is not a monthly spending cap. Database
correctness must not depend on it. Verify account quota permits the reservation before deployment.

Lambda images must run with a read-only filesystem; temporary writes belong under `/tmp`.
Use an ECR repository in the same Region. [AWS image requirements](https://docs.aws.amazon.com/lambda/latest/dg/images-create.html)

Add a minimal `GET /health/ready`: return 200 only after required configuration, database
access, and ready schema metadata are verified. Return no configuration or practice data.
Disable production Swagger/OpenAPI routes unless separately protected.

Configure the adapter:

```text
AWS_LWA_PORT=8080
AWS_LWA_READINESS_CHECK_PATH=/health/ready
AWS_LWA_READINESS_CHECK_HEALTHY_STATUS=200
AWS_LWA_ASYNC_INIT=true
AWS_LWA_INVOKE_MODE=response_stream
```

The Function URL must also use `RESPONSE_STREAM`. Ordinary JSON and SSE responses both go
through this configuration. Verify actual incremental delivery, not just the content-type
header. Retain the existing bounded MVC/SseEmitter approach.

The Web Adapter supports Spring Boot, container images, and streaming.
[Web Adapter documentation](https://github.com/aws/aws-lambda-web-adapter)

Measure cold-start and warm-request latency before choosing further startup optimizations.
Do not provision idle compute or schedule periodic warm-up calls in the initial design.

## 4. Configuration and secrets

Use ignored `.env.local`, `.env.staging`, and `.env.prod` files. Supply an example for each
with no real credentials. Restrict local secret-file permissions and exclude them from the
Docker build context and generated artifacts.

| Setting | Purpose |
|---|---|
| `DEPLOY_AWS_PROFILE` | Local deployment credential profile |
| `DEPLOY_REGION` | Deployment Region |
| `DEPLOY_ENVIRONMENT` | Resource namespace |
| `SANKALPA_PERSISTENCE` | `sqlite` or `dynamodb` |
| `SANKALPA_DYNAMODB_TABLE` | Database table |
| `SANKALPA_DYNAMODB_ENDPOINT` | Local-only endpoint override |
| `SANKALPA_TIMEZONE` | Existing shared practice time zone |
| `SANKALPA_API_TOKEN` | Application bearer credential |
| `SANKALPA_ASSISTANT_ENABLED` | Assistant availability |
| Existing `SANKALPA_LLM_*` settings | Provider configuration |
| Proposed assistant daily/minute limits | Durable usage controls |

Initially, production uses DynamoDB and disables the assistant. `America/Chicago` is suitable
only while it agrees with the app's practice time zone. Preserve the existing offset-free
timestamp interpretation; this deployment does not redesign travel or time-zone semantics.

The deployment tool parses configuration as data rather than executing it as shell code.
Whitelist runtime variables, reject an AWS local-endpoint override, and do not inject reserved
Lambda variables or static AWS credentials. Lambda uses its execution role; local AWS operations
use the deployment profile. DynamoDB Local may use dummy credentials only for its local endpoint.

Supply application secrets as Lambda environment variables through `NoEcho` CloudFormation
parameters. Do not save them in checked-in templates, release manifests, command output,
`samconfig` files, or shell arguments that expose them. The script uses structured SDK input or
restricted temporary input that it removes afterward.

Lambda encrypts environment variables at rest using its default AWS-managed key without a
separate customer-managed-key charge. Authorized AWS identities can still inspect them.
[Lambda encryption guidance](https://docs.aws.amazon.com/lambda/latest/dg/configuration-envvars-encryption.html)

The user permits a private bundled `.env`; bundling is unnecessary in the selected design.
One image can therefore be reused across environments. Secrets Manager is not required.

Environment values are version-specific. Rotation publishes a new release. If the old token
has been revoked, rollback republishes the compatible old code with current credentials rather
than blindly pointing the alias at an old secret-bearing configuration.

## 5. Backend changes

The current persistence interfaces are
[`SankalpaRepository`](../../../backend/src/main/java/com/sankalpa/application/port/SankalpaRepository.java),
[`SessionRepository`](../../../backend/src/main/java/com/sankalpa/application/port/SessionRepository.java), and
[`ProposalRepository`](../../../backend/src/main/java/com/sankalpa/application/conversation/ProposalRepository.java).
Current transaction decorators and service identity initialization depend on JDBC.

Introduce:

- `DynamoSankalpaRepository`, `DynamoSessionRepository`, and `DynamoProposalRepository`.
- `DynamoUnitOfWork`, shared by practice and proposal use cases.
- DynamoDB transactional decorators implementing the existing use-case interfaces.
- A storage-neutral metadata path used by service identity and capability responses.
- A full-ledger validation/import tool outside ordinary startup.
- Conditional wiring for SQLite/JDBC and DynamoDB persistence modes.

Keep the existing domain and application types authoritative. AWS SDK types remain in adapters.
Split configuration so DynamoDB does not create a JDBC datasource, transaction manager, schema,
or SQLite migration bean. Keep the existing SQLite path usable for its current local workflow;
AWS-equivalent local verification runs the DynamoDB path.

Implementation files include the container/Compose definitions, two CloudFormation
templates, unified operator scripts, environment examples, adapters, and verification tools.
See the implementation review and operator guide for the delivered files and execution commands.

## 6. DynamoDB model

Use one Standard, on-demand table per environment:

```text
PK: String
SK: String
```

Business records use `PK=PRACTICE#default`. This deliberately favors simplicity for one small
personal practice; it is not a multi-tenant or high-throughput partitioning design.

| Sort key | Contents |
|---|---|
| `META` | Schema version, service UUID, practice revision, commit sequence, initialization status |
| `VOW#<id>` | Declaration, commitment, lifecycle, version, root/source relationships, ordered history |
| `SERIES#<root>#<duration>#<id>` | Series membership reference |
| `EXTENSION#<source>` | Unique direct-extension claim |
| `SESSION#<id>` | Session identity, owner, performed time, ACTIVE/DELETED state |
| `JOURNAL#<timestamp>#<id>` | Active canonical journal projection |
| `OWNER#<vow>#<timestamp>#<id>` | Active session projection by logging owner |
| `PROPOSAL#<id>` | Proposal payload, state, confirmation, and result |
| `RUN#<id>` | Unique run-to-proposal reference |
| `THREAD#<id>` | Pending proposal reference |
| `CONFIRM#<id>` | Unique confirmation claim |

Delete the active journal and owner projections when deleting a session, but retain the canonical
`SESSION` tombstone permanently. This combines the fact and identity ledger into one durable
record while preserving the existing application interface behavior.

Projection writes and the canonical record commit together. A direct-extension claim makes
branch prevention independent of a query that might race another creator. Proposal run and
confirmation claims supply persistent identity protection, including after cold starts.

Use normalized UUID text, fixed-width duration keys, and fixed-width local timestamp keys
including fractional seconds. Query newest first with the existing timestamp/UUID tie-breaker.
Handle all `LastEvaluatedKey` continuations and keep date bounds equivalent to the existing API.

Primary-table queries and strong reads avoid relying on eventually consistent secondary indexes.
Do not add indexes initially. Per-owner and series lookups use their stored references.

The existing numeric session-page API still needs to traverse preceding matching entries and
compute totals. Cursor-based reads use key boundaries and merge owner streams for a linked
series. Preserve current ordering, contribution rules, page limits, and revision headers.

Initially store lifecycle history in the vow document. Validate the unchanged committed history
prefix before updates. Check encoded item sizes during import and verification. If an actual
vow approaches DynamoDB's 400 KB item limit, implement segmented history before importing or
extending it. Do not truncate history or silently relax lifecycle auditing.

## 7. Transactions and consistent reads

### Unit of work

Each application operation:

1. Reads `META` strongly and captures `commitSequence` and `practiceRevision`.
2. Loads records strongly, retaining an attempt-local identity map.
3. Runs existing domain rules and buffers persistence changes.
4. Supplies read-after-write behavior from the buffered state.
5. Coalesces operations on the same key into one action.
6. Commits with `TransactWriteItems`, conditionally updating the captured metadata sequence.
7. Returns only after a successful commit.

Every business-record mutation increments `commitSequence`; only practice changes increment
`practiceRevision`. Proposal-only operations must not invalidate practice cursor semantics.
Operational counters and leases do not alter practice facts or their revision.

The metadata condition serializes competing business writes logically. Parent/series lock
methods become reads whose validity is protected at commit, rather than process-local locks.
Conditional identity creation additionally protects immutable claims.

On a known contention failure, discard the attempt, reload, and retry with bounded jitter.
Mutated aggregate instances and buffered writes must not leak into another attempt.
Map exhausted contention to the existing application refusal where applicable.

Do not split an atomic business operation into independent write batches. DynamoDB supports
up to 100 distinct transaction items and 4 MB; validate limits before sending. One transaction
cannot contain multiple actions targeting the same item.
[DynamoDB transactions](https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/transaction-apis.html)

For SDK/network retries, reuse the exact write batch and its client request token. A changed
attempt gets a new token. An ambiguous outcome must not trigger an unchecked rerun of a
non-idempotent command. Session, extension, run, and confirmation replay records remain
permanent; the SDK token's limited retry window is not their replacement.

The ordinary declaration endpoint has no universal idempotency contract. Preserve that fact;
do not automatically retry all POST requests in iOS or the operator tool.

### Snapshots

Strong consistency does not make multiple queries one snapshot. The decorator brackets the
whole read, including all query pages, with strong metadata reads. Accept the assembled result
only if `commitSequence` is unchanged. Discard and retry a changed unbound read; preserve
`READ_SNAPSHOT_CHANGED` when an explicitly required practice revision no longer matches.

Every business writer, including import/repair tooling used against a live table, must respect
the metadata protocol. Import normally runs against an offline empty target. Console edits of
business items bypass the protocol and are not a supported operational repair procedure.

Test concurrent commits between each database fetch and the final revision check. No response
body or success SSE effect may be emitted from an uncommitted or invalidated unit of work.

### Proposal resolution

Successful confirmation commits its practice changes, identity claims, proposal result, pending
thread update, and practice revision together. A domain refusal discards any buffered practice
effects and commits only the proposal's REJECTED resolution and related proposal bookkeeping.
Expired/cancelled resolutions retain their current replay behavior.

Do not use TTL on session tombstones, confirmation/run identities, or proposal replay records.

## 8. Assistant and HTTP boundary

Function URL authentication is `NONE`; the existing backend bearer filter authenticates API
calls. Add production configuration validation that rejects a missing or blank token.

Allow only intended API routes and the minimal readiness endpoint externally. Disable public
Swagger and diagnostic/configuration routes. Continue request-size, protocol, and transcript
limits. Provider keys remain server-side and microphone behavior remains unchanged.

Function URL policies must grant both `lambda:InvokeFunctionUrl` and `lambda:InvokeFunction`
for the intended alias, using the appropriate Function URL conditions. Requests rejected by
the application still consume a Lambda invocation.
[Function URL access control](https://docs.aws.amazon.com/lambda/latest/dg/urls-auth.html)

The coordinator's current instance-local active-run guard and rate limiter cannot coordinate
multiple execution environments. Add DynamoDB operational records:

- `LEASE#THREAD#<id>`: conditional thread lease, run ID, fencing token, and expiry.
- `RATE#ASSISTANT#<minute-or-day>`: conditional usage counter with expiry.

Claim a lease before provider work; release it only when the fencing token still matches.
Choose an expiry beyond the bounded run deadline and check ownership before creating effects.
A proposal/effect transaction must include a condition on the current lease token and its
validity; a separate ownership read alone would race a new lease holder. Buffer this condition
in the unit of work alongside its business writes. A competing or expired owner must not
continue proposal creation. Existing durable proposal
identities still govern replay. Rate counters and lease transitions use conditional operations.
TTL may remove expired operational records but does not determine whether a lease is valid.

Do not hold a database transaction while waiting for a provider. Configure daily and minute
limits and provider request timeouts. One accepted run can include several model rounds, so
run limits alone do not specify an exact provider bill.

Keep the assistant disabled for initial deployment. Enable it after AWS SSE, proposal, lease,
disconnect, and replay tests pass. Complete or cancel request-owned work before the Lambda
invocation ends; no work depends on background threads continuing afterward.

## 9. Startup, migration, and recovery

Move full ledger validation out of `ServiceInstanceIdentity` startup. Every cold start checks
configuration, table access, ready status, supported schema, and the persisted UUID/revision.
The UUID belongs to the practice, not the deployment or execution environment.

Provide `db init`, `db import`, and `db validate` operations. Initialization conditionally creates
metadata once for an empty target. Runtime instances do not create tables or run full migrations.

Import from a consistent SQLite backup into an empty DynamoDB target marked IMPORTING:

- Preserve all entity IDs, lifecycle origins, root/source links, session identities, proposal
  states, service UUID, and practice revision.
- Create projections and uniqueness claims from validated canonical records.
- Verify counts, relationships, ACTIVE/tombstone consistency, audit ordering, and item sizes.
- Mark READY only after validation completes; startup refuses incomplete imports.
- Restart an interrupted import explicitly against a clean target or a validated resumable
  import manifest. Do not mix partial imports with live practice writes.

Before cutover, drain iOS pending writes where practical, stop new writes to the old backend,
take the backup, import/validate, deploy, and then change the client endpoint. Preserve the old
backup. The client must not silently rebind pending operations to a different service UUID.

Enable production point-in-time recovery and exercise restoration to a new table. Recovery
requires updating table configuration and IAM access and restarting against the verified target.
Clear old execution-environment state through a new deployment before resuming requests.

An application rollback uses the same database and requires compatible stored formats. After
cloud writes occur, switching back to the old SQLite file requires explicit data reconciliation;
alias rollback does not transfer data.

## 10. iOS changes

Update [`ServiceLocation`](../../../app/SankalpaCore/Sources/SankalpaStorage/ServiceLocation.swift)
so a parsed HTTPS address without a port uses 443. Preserve current explicit local addresses
and local host shorthand, including its 8080 behavior. Normalize display/cache identity for
equivalent HTTPS host and host:443 settings without changing a practice's service binding.

Both REST and assistant clients use the configured root Function URL. Retain Keychain token
storage and platform TLS validation. No AWS SDK or AWS credentials are needed in the phone.

Handle Function URL 429/503 responses that are not application/problem+json. Use bounded
backoff for reads and operations already proven replay-safe. Preserve durable offline session
identities, cancellation/deletion intent, revision restart behavior, and capability negotiation.

Keep the URL configurable and report the actual deployed endpoint. Destruction/recreation can
change it even though normal alias promotion does not.

## 11. Unified lifecycle workflow

The interface is implemented by an operator script under `backend/scripts/`:

```text
backend build
backend deploy --target local --environment dev
backend test --target local --environment dev
backend status --target local --environment dev
backend logs --target local --environment dev
backend stop --target local --environment dev

backend deploy --target aws --environment staging
backend test --target aws --environment staging
backend deploy --target aws --environment prod
backend status --target aws --environment prod
backend logs --target aws --environment prod
backend rollback --target aws --environment prod
backend stop --target aws --environment prod
backend start --target aws --environment prod
backend cleanup --target aws --environment prod
```

Run these operations with `backend/scripts/backend`; see `backend/scripts/README-aws.md` for concrete commands. Support an
environment-file argument and validated parameter overrides; explicit arguments override the
selected file. Report nonsecret effective settings before deployment.

### Local

Docker Compose runs the same application image and DynamoDB Local, with a persistent development
volume. Tests use disposable containers/data. The tool can stop a previously managed Java
process when replacing that deployment, using the existing process-identity checks; it must
refuse to stop an unrelated process occupying the selected port.

Local readiness is followed by an authenticated capability check, not merely accepting 401 as
evidence that all configuration is correct. Failed replacement restores the prior compatible
release where feasible and preserves data and useful failure logs.

### AWS releases

1. Verify locally and build an immutable image.
2. Push it and resolve the exact digest.
3. Apply a CloudFormation change set that publishes the candidate and keeps production pinned
   to its current version.
4. Wait for infrastructure and function updates to finish.
5. Validate the candidate URL: staging supports mutation tests; production checks are read-only.
6. Promote through a second change set updating only the selected production version/alias.
7. Record current and previous compatible versions and their image/configuration identities.

Templates explicitly separate candidate creation from production promotion. The initial deployment
creates the first production alias; a later candidate failure does not move an existing alias.
Console inspection does not create competing ownership of stack-managed settings.

`stop` updates reserved concurrency to zero; `start` restores the declared value through the
deployment definition. Already-running invocations can finish. Rollback promotes a compatible
version/configuration through the same stable alias.

Deleting a Function URL cannot preserve its address on recreation.
[Function URL lifecycle](https://docs.aws.amazon.com/lambda/latest/dg/urls-configuration.html)

### Cleanup

Discover owned resources and referenced versions before deleting anything. Preserve every alias
target, the recorded rollback release, and their images. Remove obsolete version resources through
their owner; remove retained, unreferenced versions only after confirming they are no longer stack
resources. Delete images only after no retained version requires their digest.

Do not expire production images solely by latest-N ordering. ECR lifecycle rules may target
explicitly disposable scratch artifacts, with a preview; release-image cleanup uses references.
Keep enough release metadata to perform this calculation after an interrupted deployment.

Default production cleanup never deletes the table. Explicit staging teardown can remove its
disposable table, repository, and log group after removing the application stack. Report retained
resources and ongoing storage charges.

## 12. Cost and observability

The initial $1–$5/month target is an allowance for a small personal workload, not a guaranteed
minimum, maximum, or account-wide bill. No introductory credits are necessary to the estimate.

| Component | Cost behavior/control |
|---|---|
| Function URL | No additional endpoint fee; Lambda duration and requests remain billable |
| DynamoDB | On-demand reads/writes, stored data, and enabled backups; avoid unbounded access patterns |
| ECR | Retained image storage; remove only images not needed by releases |
| CloudWatch | Log ingestion, retention, queries, and any separately enabled monitoring features |
| Deployment storage | Small CloudFormation/S3 artifacts and requests where needed |
| Transfers | Small HTTPS responses; account-wide free transfer allowances may apply |

Sources: [Lambda endpoint choices](https://docs.aws.amazon.com/lambda/latest/dg/furls-http-invoke-decision.html),
[DynamoDB pricing](https://aws.amazon.com/dynamodb/pricing/),
[ECR pricing](https://aws.amazon.com/ecr/pricing/), and
[CloudWatch pricing](https://aws.amazon.com/cloudwatch/pricing/).

Keep logs for 14 days, disable verbose request/provider logging, and avoid scheduled warm-ups
and continuous staging. Capture release, request correlation, operation/status, duration, and
safe error codes. Do not log practice content or credentials.

Set a $5 monthly budget alert. It reports spending and is not an enforcement mechanism.
Reserve concurrency and assistant quotas limit exposure but do not prove a fixed-dollar cap.
Model-provider charges, optional domain renewal, taxes, and unrelated workloads are separate.

## 13. Verification and delivery

Implement in this order:

1. Persistence selection, metadata abstraction, and DynamoDB model.
2. Unit of work, repository adapters, and local concurrency/replay tests.
3. Proposal transactions, distributed assistant guards, and import/validation tools.
4. Container/Compose packaging and local lifecycle operations.
5. CloudFormation templates and staged AWS release/rollback/cleanup tools.
6. iOS HTTPS parsing, endpoint handling, and retry classification.
7. Temporary AWS verification, migration rehearsal, and physical-device validation.
8. Production migration/cutover; optionally enable the assistant afterward.

Required evidence includes existing domain/HTTP contract tests; concurrent log/delete/lifecycle
and extension races; proposal confirmation/refusal/replay; multi-page snapshot invalidation;
interrupted import; item/transaction limit rejection without partial writes; cold/warm JSON and
SSE; incorrect/missing-token failures; stable URL/UUID across releases; failed candidate and rollback;
credential rotation; stop/start; safe cleanup; backup restoration; and offline iPhone replay.

Use temporary AWS staging for behavior local emulation cannot prove: execution-role permissions,
actual Function URL adaptation/streaming, account quotas, and release lifecycle. Do not treat local
emulation or the Console Test button as proof of production HTTP behavior.

### Requirements traceability

| Requirements | Design sections |
|---|---|
| AWS-001–AWS-010 | 2, 3, 4, 11, 13 |
| AWS-011–AWS-015 | 1, 3, 8, 10, 11 |
| AWS-016–AWS-020 | 4, 8, 11 |
| AWS-021–AWS-026 | 5, 6, 7, 9, 13 |
| AWS-027–AWS-028 | 3, 7, 8, 13 |
| AWS-029–AWS-031 | 2, 11, 12 |
| AWS-032 | 13 and the Console guide |
