# Sankalpa: Step-by-Step AWS Console Setup

Status reviewed October 17, 2026. The production foundation and SQLite import are complete.
Production REST deployment and provider streaming are verified. Live acceptance is tracked in [implementation-review.md](implementation-review.md).
For an existing installation, inspect its status and resume at the first incomplete step; do not
recreate resources or repeat database initialization/import.

See the [requirements](../../requirements/aws.md) and [detailed design](design.md).

## Before starting

Use CloudFormation through the Console so initial setup and later scripted deployments use the
same infrastructure definitions. Do not manually create duplicates of stack-managed resources.

Available implementation files:

```text
infra/foundation.yaml
infra/application.yaml
Environment-file examples
Backend lifecycle, database initialization/import, and validation tools
```

See [automated operator commands](../../../backend/scripts/README-aws.md) to run setup and
deployment from the Mac. The following steps show the corresponding Console settings. A container must be built and pushed locally; the AWS Console cannot
build the Spring Boot application for you.

All example names use production in `us-east-1`. Rehearse the application setup in staging first,
using its own table, role, repository, credentials, and stack names.

## Step 1 — Account, access, and Region

1. Sign in to the AWS Console with the normal administrator/deployment identity.
2. Use the root account only for account administration and enable its MFA.
3. Record the account ID shown in the account menu.
4. Select **US East (N. Virginia), us-east-1**.
5. Keep this Region for CloudFormation, DynamoDB, ECR, Lambda, and CloudWatch.

Set up a local AWS CLI profile using the account's normal short-lived credential mechanism,
such as IAM Identity Center. The deployment profile remains on the Mac; it is not embedded in
the application or phone.

For the dedicated `sankalpa-deployer` user and local profile, use the complete
[deployer setup guide and bootstrap script](deployer-setup.md). It separates the administrator
bootstrap session from routine deployment, attaches the policy to the correct user, and includes
the exact identity/CloudFormation/DynamoDB verification commands.

The deploying identity or CloudFormation service role needs to manage the named Sankalpa
resources and pass the Sankalpa runtime role. The local image publisher needs ECR push access;
the initialization/import operator needs the selected table's item operations. These permissions
are separate from the restricted runtime role created by the foundation template.

The implementation provides `infra/deployer-policy.json`; replace `REGION` and `ACCOUNT_ID` before applying it.
do not attach broad application-runtime administrator permissions to solve deployment errors.

## Step 2 — Check concurrency and set a budget

Use shared concurrency for this small personal backend: `DEPLOY_CONCURRENCY=-1` and the
application template's `ReservedConcurrency=-1`. The template omits the reservation property.
No quota increase is required; the function shares the existing account pool (currently 10).
The previous quota request is no longer a deployment prerequisite.

Do not enter -1 in Lambda's reserved-concurrency Console field: choose **Use unreserved
account concurrency** there. Manage the declared value through CloudFormation/operator tools.
A positive reservation is optional and requires AWS's 100-unit unreserved headroom.
[Concurrency guidance](https://docs.aws.amazon.com/lambda/latest/dg/lambda-concurrency.html)

Then open **Billing and Cost Management → Budgets**:

1. Choose **Create budget**.
2. Select a monthly cost budget.
3. Name it `Sankalpa Monthly` and enter **$5**.
4. Create actual-cost alerts at **80%** and **100%**.
5. Optionally create a forecast alert at **100%**.
6. Enter the operator's notification email.

Choose account-wide scope for a dedicated account. For a shared account, activate the `Project`
cost-allocation tag and configure an appropriate filter once resource tags appear. A filtered
budget does not include untagged or unrelated charges.

If `DEPLOY_BUDGET_EMAIL` is configured, the setup command can create this budget, but the
example deployer policy does not include Budgets permissions. Create/verify it with the
administrator identity, then omit that setting from routine deployer setup runs, or grant the
specific budget permissions separately. Verify the notification thresholds and subscriber
address; finding an existing budget by name alone does not prove the alerts are correct.

A budget alert does not stop the application automatically.
[Budget setup](https://docs.aws.amazon.com/cost-management/latest/userguide/create-cost-budget.html)

## Step 3 — Create the foundation stack

Use the supplied `infra/foundation.yaml`:

1. Open **CloudFormation → Stacks → Create stack → With new resources**.
2. Choose **Upload a template file** and upload `foundation.yaml`.
3. Name the stack `sankalpa-prod-foundation`.
4. Set `Environment=prod`, `ResourcePrefix=sankalpa`, and leave `RestoredTableName` empty
   for the original table. On the stack options page add `Project=Sankalpa`,
   `Environment=prod`, and `ManagedBy=CloudFormation` stack tags. The operator requires
   these ownership tags; template resource tags do not substitute for stack tags.
5. Review parameters, tags, resource changes, and retention behavior.
6. Acknowledge creation of named IAM resources.
7. Create the stack and wait for **CREATE_COMPLETE**.
8. Open **Outputs** and record `TableName`, `RepositoryUri`, `RuntimeRoleArn`, and `LogGroupName`.

If creation fails, inspect stack events before retrying. Do not create another namespace simply
to bypass a failed stack. [CloudFormation Console instructions](https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/cfn-console-create-stack.html)

## Step 4 — Verify and initialize DynamoDB

Open **DynamoDB → Tables → sankalpa-prod** and check:

| Setting | Expected value |
|---|---|
| Status | Active |
| Partition key | `PK`, String |
| Sort key | `SK`, String |
| Capacity | On-demand |
| Table class | Standard |
| Encryption | Default AWS-owned key |
| Secondary indexes | None |
| Deletion protection | Enabled |
| Streams/global replication | Disabled |

Under **Backups**, verify point-in-time recovery is enabled with a 35-day window.
If the template uses `ttlEpoch` for operational records, verify TTL is configured for that
attribute. Identity/tombstone/proposal replay records must not carry TTL values.
[Recovery configuration](https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/PointInTimeRecovery_Howitworks.html)

The tool is the repository's [`backend/scripts/backend`](../../../backend/scripts/backend)
command-line script, implemented by `aws_backend.py`. Run it in a terminal on your computer from
the `backend/` directory between Console steps. With `--target aws`, it reads `.env.prod`, uses
the selected AWS credential profile, and writes to the **AWS DynamoDB table**; this is not an
offline operation or a tool inside the AWS Console.

Prepare its Python dependencies once:

```sh
cd backend
./scripts/bootstrap-tools.sh
```

For this installation the import has already succeeded. Run `db validate` below; do not
initialize or reimport the populated target. For a new installation, choose **one** of the
following data operations. To migrate your existing SQLite practice, stop
writes to the old backend, keep a consistent backup, and run this before creating the application
stack. The backup must have the current linked schema. For an older backup, follow the
[copy-and-migrate procedure](../../../backend/scripts/README-aws.md#preparing-an-older-sqlite-backup)
first. Replace the source path with your prepared backup's actual location:

```sh
./scripts/backend db import --target aws --environment prod \
  --sqlite /absolute/path/to/consistent-backup.db
```

For a completely new practice with no existing data to migrate, use this instead:

```sh
./scripts/backend db init --target aws --environment prod
```

Do not run `db init` before importing: import requires an empty target. Then validate the chosen
operation's result:

```sh
./scripts/backend db validate --target aws --environment prod
```

Validation checks the imported structure and the backend's domain rules. The importer preserves
the original service identity and marks the practice READY only after its checks succeed. See the
[operator guide](../../../backend/scripts/README-aws.md#aws-setup-and-data-preparation) for prerequisites
and recovery from an interrupted import.

Creating a table does not initialize its practice metadata. Do not manually invent a service UUID
when importing an existing practice, and do not set an incomplete import to READY in the Console.

## Step 5 — Verify the execution role

Open **IAM → Roles → sankalpa-prod-runtime**.

The trust relationship permits `lambda.amazonaws.com`. Runtime permissions are scoped to the
production table and pre-created log group. The table ARN is:

```text
arn:aws:dynamodb:us-east-1:<ACCOUNT_ID>:table/sankalpa-prod
```

Expected table actions:

```text
dynamodb:DescribeTable
dynamodb:GetItem
dynamodb:Query
dynamodb:PutItem
dynamodb:UpdateItem
dynamodb:DeleteItem
dynamodb:ConditionCheckItem
```

Transaction access uses the underlying item permissions.
[Transaction IAM guidance](https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/transaction-apis-iam.html)

Log permissions include `logs:CreateLogStream` and `logs:PutLogEvents` for
`/aws/lambda/sankalpa-prod`. The template pre-creates that group.

The role must not delete tables, administer cloud resources, or access the staging table.
Verify the ECR retrieval policy permits Lambda to retrieve the selected private image.

## Step 6 — Verify ECR and publish the image

Open **Amazon ECR → Private registry → Repositories → sankalpa-prod**.

Check private visibility, AES-256 encryption, immutable release tags, and no enhanced paid scanning
in the initial deployment. Do not configure latest-N release-image expiry.

Choose **View push commands** for the repository's local authentication/upload instructions.
The lifecycle tool will build, verify, and push the Linux ARM64 image with an immutable tag,
such as `release-20261009-001`.

Record the full repository URI and image digest. The application template deploys the digest.
An image in the same Region is required. Do not proceed without a verified Lambda-compatible
image. [Container deployment requirements](https://docs.aws.amazon.com/lambda/latest/dg/images-create.html)

## Step 7 — Prepare production configuration

For a new installation only, copy the supplied production environment example to an ignored
`.env.prod` file. Preserve an existing configured file. Configure account, Region, profile,
time zone, and a randomly generated bearer token. The table comes from foundation Outputs.
Keep the assistant disabled for initial verification, then enable it after staging acceptance.
Do not overwrite existing secrets or change assistant settings without recording that choice.

The user is responsible for retaining this configuration locally. The deployment tool reads it
and sets Lambda environment variables without requiring Secrets Manager.

Keep `SANKALPA_DYNAMODB_ENDPOINT` absent on AWS. Do not put AWS access keys in the runtime
configuration, and do not override Lambda's reserved `AWS_REGION` variable.

Use `.env.staging` with different credentials for staging. Never deploy a real production token
or practice dataset to an environment intended for destructive tests.

## Step 8 — Create the application stack

Prefer `./scripts/backend deploy --target aws --environment prod`: it builds and pushes the
image, supplies every runtime parameter, validates the candidate, and manages promotion.
For a manual first deployment, open **CloudFormation → Create stack**, upload `application.yaml`, and name the stack
`sankalpa-prod-app`.

Enter the template's corresponding parameters:

| Parameter | Value |
|---|---|
| Environment | `prod` |
| ResourcePrefix | `sankalpa` (function name derives from prefix and environment) |
| TableName | Foundation output |
| RuntimeRoleArn | Foundation output |
| ImageUri | ECR image URI with digest |
| ReleaseId | Unique release label, for example `release-20261017-001` |
| ProductionVersion / RollbackVersion | Empty on the first deployment only |
| Architecture | `arm64` |
| MemorySize | `1024` |
| TimeoutSeconds | `90` |
| ReservedConcurrency | `-1` (omit reservation; use shared pool) |
| PracticeTimezone | `America/Chicago`, if it matches the app |
| ApiToken | Generated application bearer token |
| AssistantEnabled | `false` |

Also review `LlmProvider`, `LlmApiKey`, `LlmModel`, `LlmReasoningEffort`, `LlmTimeout`,
`RunsPerMinute`, and `RunsPerDay` against the selected environment file. Add the same stack
ownership tags as in Step 3. Subsequent releases should use the operator tool rather than
blanking the version parameters: doing that can move production before candidate validation.

Secret parameters use `NoEcho`; authorized Lambda administrators can still access environment
configuration. Review the stack changes and create it. Wait for **CREATE_COMPLETE**.

The template creates the initial published version, production/candidate aliases, URLs, and
permissions. On subsequent releases, the staged deployment tool holds production at the
current version until candidate verification succeeds.

## Step 9 — Verify Lambda and streaming settings

Open **Lambda → Functions → sankalpa-prod**.

Check container package type, ARM64 architecture, release digest, 1,024 MB memory, 90-second
timeout, 512 MB temporary storage, shared/unreserved concurrency, no provisioned concurrency, no VPC,
and the expected execution role.

Under **Configuration → Environment variables**, check persistence mode, table, time zone,
assistant availability, token presence, and:

```text
AWS_LWA_PORT=8080
AWS_LWA_READINESS_CHECK_PATH=/health/ready
AWS_LWA_READINESS_CHECK_HEALTHY_STATUS=200
AWS_LWA_ASYNC_INIT=true
AWS_LWA_INVOKE_MODE=response_stream
```

Inspect the **prod alias** and its Function URL configuration:

| Setting | Expected value |
|---|---|
| URL target | `prod` alias |
| Authentication | `NONE` |
| Invoke mode | `RESPONSE_STREAM` |
| CORS | Unconfigured for native iOS |

The backend requires the bearer token. AWS URL authentication `NONE` delegates authentication
to the application. Verify both URL invocation permissions exist with the intended alias and
conditions. [URL permissions](https://docs.aws.amazon.com/lambda/latest/dg/urls-auth.html)

If inspecting the invoke mode, the Console offers its Function URL edit controls. Both the URL
and adapter must stream. Correct unexpected settings through the deployment definition and a
stack update, rather than leaving an undocumented Console override.
[Streaming configuration](https://docs.aws.amazon.com/lambda/latest/dg/config-rs-invoke-furls.html)

Copy the production URL from stack Outputs or the alias configuration:

```text
https://<generated-id>.lambda-url.us-east-1.on.aws/
```

Do not delete/recreate it for a release. No Route 53 zone, certificate request, custom domain,
or API Gateway setup is necessary.

## Step 10 — Verify logs and HTTP behavior

Open **CloudWatch → Logs → Log groups → /aws/lambda/sankalpa-prod**.
Verify Standard log class and 14-day retention. Inspect startup/readiness failures without
printing secrets or request bodies.

Use the operator tool to check the actual HTTPS endpoint:

- `/health/ready`: minimal 200 response after successful initialization.
- `/api/v1/capabilities` without credentials: 401.
- The same capability request with the configured token: 200 and the expected service UUID.

The tool obtains the token from its selected configuration file so it need not appear in shell
history. Run mutation tests in isolated staging, not against the production practice.

The Console's Lambda **Test** button alone does not verify HTTP adaptation or incremental SSE.

## Step 11 — Connect the iPhone

The verified production address for this installation is:

```text
https://xkf54pbp4oata4kxbnwsy3hk2a0rjwxl.lambda-url.us-east-1.on.aws/
```

Use that base URL in the **Computer** field of **Sankalpas → Sankalpa service**. Under
**Authentication**, enter only the `SANKALPA_API_TOKEN` value from the private local
`backend/.env.prod` file (without the key name, quotes, or a `Bearer ` prefix). Do not use an
AWS key or the model-provider key. Save and refresh. The existing 2 sankalpas should appear.
If **Save** is disabled because pending session changes exist, resolve/send them against the
old service first; the current UI prevents switching addresses while changes are pending.
A launch argument/environment override can also take precedence over this saved address.

The Mac may be switched off after deployment. Use the connected client under `app/`; `app2/`
is a separate local-file app. If the installed app is older, build/install the current
`app/Sankalpa.xcodeproj` using the **Sankalpa** scheme and your physical iPhone as the destination.
The first request after Lambda has gone idle can take tens of
seconds while Java starts; the current read retry behavior handles transient failures.


The connected client under `app/` already includes the HTTPS default-port fix:

1. Open **Sankalpas → Sankalpa service**.
2. Enter the production Function URL.
3. Enter the matching bearer token under **Authentication**.
4. Confirm the practice time zone.
5. Refresh and verify the imported practice and service identity.

HTTPS addresses use port 443 when no port is given; an explicit `:443` remains compatible.
Keep pending operations bound to their persisted service identity; do not manually force them
onto an unrelated empty practice.

Verify a second application deployment preserves the URL and service UUID. Validate offline
session replay and correction on a physical device using the planned acceptance scenarios.

## Step 12 — Enable the assistant after verification

Run streaming, thread-lease, confirmation, replay, and disconnect scenarios in staging first.
Then review the production environment file with provider configuration, assistant enablement,
and daily/minute limits. This installation already has provider settings configured; retain
them privately and verify behavior before declaring assistant acceptance. Publish a candidate, verify it, and promote it.

Verify SSE events arrive incrementally and a replayed confirmation does not create another
practice change. The provider key stays on Lambda; only the application bearer token goes to
the iPhone. Check provider billing separately from the AWS budget.

## Step 13 — Releases, stopping, and cleanup

Use the operator tool for routine changes. It updates the same CloudFormation definitions,
waits for completion, validates candidates, and reports the resulting version and URL.

| Operation | Expected behavior |
|---|---|
| Deploy | Publish/validate candidate, then promote; keep prior compatible release |
| Stop | Declare reserved concurrency zero; reject new URL invocations |
| Start | Remove the zero reservation and resume shared account concurrency |
| Rollback | Republish compatible old code with current file-supplied credentials, validate, then promote without changing URL |
| Cleanup | Delete only owned, unreferenced versions and unneeded image digests |
| Staging teardown | Remove application first, then explicitly remove disposable retained foundation resources |

If emergency stopping is performed directly in **Lambda → Configuration → Concurrency**, record
it and reconcile the deployment configuration before the next release; otherwise deployment
could restore traffic unexpectedly. Already-running invocations can finish.

Production cleanup retains the table. Stopping the function does not eliminate storage charges.
Do not delete the production Function URL as a stopping mechanism: a recreated URL is different.
[Function URL operation](https://docs.aws.amazon.com/lambda/latest/dg/urls-configuration.html)

For recovery, DynamoDB restores to a new table. Update table configuration and role access through
the definitions, redeploy, validate the restored service identity/revisions, and then resume traffic.
Exercise this in staging before relying on it for production.

## Troubleshooting

| Symptom | First check |
|---|---|
| AWS 403 before application response | URL alias, resource policy, both URL invocation permissions |
| Application 401 | Token in the selected published version and iOS Keychain |
| Phone tries port 8080 | Update to the connected client with the HTTPS fix; explicit `:443` also works |
| Lambda 429 | Stopped/busy reserved concurrency or URL request-rate limit |
| DynamoDB access denied | Runtime-role table ARN, Region, item-operation permissions |
| Readiness never succeeds | Required token, supported/READY metadata, table connectivity |
| SSE arrives all at once | URL `RESPONSE_STREAM`, adapter `response_stream`, actual HTTP test |
| Local works but AWS fails | Linux image architecture, filesystem writes, startup configuration |
| CloudFormation fails reserving concurrency | Account quota and unreserved headroom |
| Data seems missing after release | Wrong table/environment or incomplete import; stop writes and inspect |
| Stack deletion leaves charges | Retained tables, repositories, logs, backups, or images |

Console labels can evolve. Use the service/resource/property names above when navigation wording
differs, and record any material adjustment to the guide during implementation.
