# Complete Sankalpa deployment-identity setup

Run one script on your **Mac**. It handles the administrator login, IAM user and policy,
access-key creation, local AWS profile, `.env.prod` profile selection, and access verification.
You do not need CloudShell, SSO configuration, file uploads, or manual access-key copying for
this workflow. The earlier CloudShell steps are superseded by this guide.

## Run this command

Prerequisites: Python 3.11+, AWS CLI **2.32.0 or newer**, the local repository with its ignored
`backend/.env.prod`, and your existing administrator Console login. The AWS CLI installed on
this Mac was checked at version 2.38.1. No Python packages need installing for this script.

In Terminal on your Mac:

```sh
cd /Users/prashantwani/wrk/sankalpa/backend
python3 scripts/setup_aws_deployer.py \
  --account-id 516246499367 \
  --region us-east-1 \
  --admin-user pswani1-admin \
  --complete
```

Keep the terminal open. The script launches `aws login` in your browser when an administrator
session is needed. In the browser, choose your existing `pswani1-admin` session or sign in using:

| Browser field | Value |
|---|---|
| Account ID | `516246499367` |
| IAM user name | `pswani1-admin` |
| Password | That administrator's existing AWS Console password |
| MFA, if requested | That administrator's configured MFA device |

Approve the local-development login and return to Terminal. Some AWS CLI releases also offer
optional coding-agent/MCP configuration after login; answer `n` to that unrelated offer. Region,
profile names, user name, policy attachment, and access keys are supplied or handled automatically. You will not be asked for an SSO session name,
SSO start URL, or an OpenAI key.

The administrator must have IAM management and simulation permissions, plus browser local-login
permission (`SignInLocalDevelopmentAccess` or equivalent). A user name containing "admin" does
not establish those permissions. If AWS denies browser login, the administrator must enable
local-development sign-in; the script cannot grant itself access before authentication.
See the [official browser-login documentation](https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-sign-in.html).

## What the single command does

1. Checks local configuration, file paths, AWS CLI version, account ID, and Region.
2. Uses the separate `sankalpa-bootstrap-admin` profile for the administrator's temporary browser
   session. Verifies the selected IAM identity and target account before changing IAM.
3. Creates or reuses `sankalpa-deployer` and `SankalpaDeployer`. The user already created in your
   CloudShell session is reused. It does not create duplicate users.
4. Renders the repository's deployment policy for the selected account/Region, updates it only
   when needed, and attaches it to the deployment user.
5. Adds missing ownership tags automatically after verifying the exact user/policy is dedicated
   to Sankalpa. A conflicting project tag, unrelated user permissions, shared policy, Console
   password, or permissions boundary stops setup before modifying those resources. The untagged,
   unused policy encountered during the earlier setup is handled without a manual tagging step.
6. Reuses a matching active deployment access key already saved locally. Otherwise creates one
   new key, captures it privately, and installs it under the `sankalpa-deployer` AWS profile.
7. Backs up existing AWS configuration files privately and updates only the named deployment
   profile. Other profiles, including the Synology backup `default` profile, remain intact.
8. Verifies the deployment caller identity and simulates key CloudFormation, DynamoDB, Lambda,
   ECR, Logs, and IAM runtime-role/pass-role operations without creating application resources.
9. Performs live read checks against the existing `sankalpa-prod-foundation` stack and its
   DynamoDB table. If the Console-created foundation has missing stack tags, it verifies the
   exact repository template, parameters and all four physical resource names, then applies a
   reviewed tag-only change set. Dynamic runtime-policy ARN references caused by those tags are
   allowed only for unchanged resources, and the runtime policy is checked against a pre-update
   snapshot afterward. Conflicting tags, different templates, replacements and direct policy
   changes are refused. It does not print practice records or write test data into production.
10. Sets `DEPLOY_AWS_PROFILE=sankalpa-deployer` in the ignored `.env.prod`, preserving its other
    settings, then reports `SETUP COMPLETE` only when the applicable checks pass.

If the foundation has not been created, the script explicitly reports that condition. IAM setup
can finish, but database access cannot be verified until you run the existing backend `setup`
command. A permission simulation is useful validation, not proof that every live deployment
request will succeed under all organization policies, resource policies, conditions, or quotas.
See [IAM simulation limits](https://docs.aws.amazon.com/cli/latest/reference/iam/simulate-principal-policy.html).

This command completes **deployment identity and local credentials setup**. It does not import
or alter your practice, create the application stack, or deploy a Lambda release.

## Credentials, interrupted runs, and reruns

AWS credentials are written to `~/.aws/credentials`, configuration to `~/.aws/config`, with mode
`600`; their standard `AWS_SHARED_CREDENTIALS_FILE` / `AWS_CONFIG_FILE` overrides are honored.
AWS credential/configuration paths inside the repository are refused. Key values are never
printed, passed as shell arguments, or placed in `.env.prod`, application images, or the phone.

Before installing a new key, its recovery record is saved privately under
`~/.aws/sankalpa-bootstrap/<account-id>-pending-key.json`. A rerun resumes this record without
creating another key. After the installed deployment identity is verified, the extra recovery
record is removed. Original AWS profile files are backed up beside them as
`*.before-sankalpa-<identifier>.bak`, also with mode `600`. Keep these backups private: they
contain the original credential/profile data.

If saving a newly issued key fails, the script attempts to delete **only that newly created key**.
It never rotates/deletes existing keys. If two keys already exist and no matching saved local
key/recovery record is available, it stops rather than guessing which key can be replaced.
Stale or unrelated deployment-profile credentials also require explicit review. An existing
user's secret access key cannot be retrieved again from AWS. Network/power loss during the key
issuance itself can leave an issued key without a recoverable secret; the script does not blindly
retry key creation or delete an unknown preexisting key.

Only one complete setup can run locally for an account at a time. IAM/key propagation is retried
for bounded intervals. If a later check fails, already completed setup is retained; rerun the
same command after resolving the reported cause. Matching users, policies, and locally installed
keys are reused. Owned policy updates preserve previous versions; if all five policy-version
slots are used, review/delete an obsolete nondefault version in IAM before retrying.

## Policy scope

The source is [infra/deployer-policy.json](../../../infra/deployer-policy.json). The deployment user
can manage `sankalpa-*` stacks, Lambda functions, DynamoDB tables, ECR repositories, log groups
and streams in the selected account and Region. IAM management is restricted to
`sankalpa-*-runtime` roles, with role passing restricted to Lambda. Caller discovery, ECR
registry authentication, Logs group discovery required by CloudFormation, and certain Lambda
account/list reads use global resource scope.

This is a trusted deployment operator with broad management actions within that namespace,
not an untrusted-user security boundary. It can modify application code, data, and runtime-role
permissions. It is not granted `AdministratorAccess`, user management, or key management.
The bootstrap administrator creates the deployment key; the deployment user does not self-issue it.
Optional account-wide budget creation is not included: leave `DEPLOY_BUDGET_EMAIL` empty and
create the budget through the Console administrator if desired.

## Review without applying

To print the policy and a plan without AWS calls:

```sh
python3 scripts/setup_aws_deployer.py \
  --account-id 516246499367 --region us-east-1 --plan
```

An existing administrator profile can be selected with `--admin-profile PROFILE` instead of the
default `sankalpa-bootstrap-admin`. It must authenticate as `pswani1-admin`, or the user explicitly
selected with `--admin-user`. The script refuses `default` and `sankalpa-deployer` as administrator
profile names to protect the existing backup/deployment profiles. Wrong existing identities are
not overwritten. `--env-file PATH` selects a different local production environment file.

The old `--apply` mode remains for IAM-only CloudShell use; it does not configure local credentials
and is not the recommended complete workflow. It retains its strict ownership-tag checks.

## Continue with migration and deployment

For a new installation, after `SETUP COMPLETE`, with writes to the old local backend stopped
and its backup migrated to the current schema using the
[copy-and-migrate procedure](../../../backend/scripts/README-aws.md#preparing-an-older-sqlite-backup):

```sh
./scripts/backend db import --target aws --environment prod \
  --sqlite /Users/prashantwani/wrk/sankalpa/tmp/sankalpa-aws-import.db
./scripts/backend db validate --target aws --environment prod
```

This installation has already completed that import; run only `db validate` when checking
it again. Use your actual migrated database path for new installations. Do not run `db init` before importing. Import requires an empty
target and no application stack. If the foundation is absent, run
`./scripts/backend setup --target aws --environment prod` first. Follow the
[operator guide](../../../backend/scripts/README-aws.md) for deployment after successful validation.

## Review and verification

The consolidated workflow was self-reviewed against the CLI/API schemas and tested with fake AWS
services and temporary credential files. Tests cover account/identity selection, dedicated-resource
adoption, shared-policy refusal, reruns, key limits, secret-output suppression, mode-600 storage,
profile preservation, file-write failure recovery, concurrency exclusion, and denied access.

Run the local verification from `backend/`:

```sh
.venv/bin/python -m unittest discover -s scripts/tests -v
```

The setup-specific suite contains 41 tests. Together with the updated operator tests, 65 tests
are discovered: 64 pass, and the separate DynamoDB Local integration test is skipped unless its
isolated endpoint is configured. Python syntax, Markdown links, and Git whitespace checks pass.
The complete workflow's request inputs were also validated against installed SDK service models.
AWS CLI skeleton checks validated policy-version and simulation argument formatting; its generated
access-key/DynamoDB example outputs failed the CLI's own output-model validation, so those output
skeletons were not counted as successful API validation. The initial verification used local fakes. The complete script was subsequently executed on
October 17, 2026 against account `516246499367`: administrator browser login, deployment policy
attachment, one deployment key, private local profile installation, ownership-tag repair on the
matching Console-created foundation, IAM simulations and live CloudFormation/DynamoDB reads all
passed. The runtime inline policy was unchanged by the tag update. Reruns reused the same key.
That identity-bootstrap run did not import practice data or deploy Lambda. Subsequent practice
import and setup review are recorded in [implementation-review.md](implementation-review.md).
Other accounts and policies can still require additional verification.
