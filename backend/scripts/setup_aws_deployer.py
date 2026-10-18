#!/usr/bin/env python3
"""Set up the Sankalpa deployment identity. --complete runs the full local workflow."""
from __future__ import annotations

import argparse
import configparser
import contextlib
import fcntl
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import time
import uuid

OWNER = {"Project": "Sankalpa", "ManagedBy": "SankalpaBootstrap"}
USER = "sankalpa-deployer"
POLICY = "SankalpaDeployer"
DEFAULT_TEMPLATE = Path(__file__).resolve().parents[2] / "infra/deployer-policy.json"


class AwsError(RuntimeError):
    def __init__(self, operation, code, missing_stack=False):
        self.code = code
        self.missing_stack = missing_stack
        super().__init__(f"{operation}: {code}. Check the selected identity and its permissions; no credential values are printed.")


class AwsCLI:
    def __init__(self, region, profile=None):
        if not shutil.which("aws"):
            raise ValueError("AWS CLI is missing; install AWS CLI v2 or run in AWS CloudShell.")
        self.options = ["--region", region, "--output", "json", "--no-cli-pager"]
        if profile:
            self.options += ["--profile", profile]

    def call(self, service, operation, **kwargs):
        command = ["aws", *self.options, service, operation]
        for name, value in kwargs.items():
            option = "--" + name.replace("_", "-")
            if isinstance(value, bool):
                command += [option if value else "--no-" + name.replace("_", "-")]
            else:
                command += [option, json.dumps(value) if not isinstance(value, str) else value]
        env = dict(os.environ, AWS_PAGER="", AWS_CLI_AUTO_PROMPT="off",
                   AWS_IGNORE_CONFIGURED_ENDPOINT_URLS="true")
        result = subprocess.run(command, capture_output=True, text=True, env=env)
        if result.returncode:
            match = re.search(r"\(([^()\s]+)\) when calling", result.stderr)
            raise AwsError(service + " " + operation, match.group(1) if match else "CLIError",
                           "does not exist" in result.stderr and operation == "describe-stacks")
        return json.loads(result.stdout) if result.stdout.strip() else {}


def optional(aws, operation, **kwargs):
    try:
        return aws.call("iam", operation, **kwargs)
    except AwsError as error:
        if error.code == "NoSuchEntity":
            return None
        raise


def render_policy(template, account, region):
    if not re.fullmatch(r"\d{12}", account):
        raise ValueError("Account ID must contain exactly 12 digits.")
    if not re.fullmatch(r"(?:us|eu|ap|ca|sa|me|af|il|mx)-(?!gov-)[a-z0-9-]+-\d+", region):
        raise ValueError("Use a commercial AWS Region, for example us-east-1.")
    text = Path(template).read_text().replace("ACCOUNT_ID", account).replace("REGION", region)
    policy = json.loads(text)
    if "ACCOUNT_ID" in text or "REGION" in text or policy.get("Version") != "2012-10-17":
        raise ValueError("Invalid or unresolved deployment policy template.")
    return policy


def owned(tags, label, adopt=False):
    actual = {tag["Key"]: tag["Value"] for tag in tags}
    if adopt and all(actual.get(key) in (None, value) for key, value in OWNER.items()):
        return actual != {**actual, **OWNER}
    if any(actual.get(key) != value for key, value in OWNER.items()):
        raise ValueError(f"Refusing to change existing {label} without matching ownership tags. Review it in IAM before adopting it; see the setup guide.")
    return False


def preflight(aws, account, policy_arn, adopt=False):
    identity = aws.call("sts", "get-caller-identity")
    if identity["Account"] != account:
        raise ValueError("Authenticated AWS account does not match --account-id; no IAM changes made.")
    if not identity["Arn"].startswith("arn:aws:"):
        raise ValueError("This policy template supports the commercial AWS partition only.")
    if identity["Arn"].endswith(":root"):
        raise ValueError("Use an IAM administrator role/session or user, rather than root credentials.")
    if identity["Arn"].endswith(":user/" + USER):
        raise ValueError("Use the bootstrap administrator identity, not the deployment user itself.")
    user = optional(aws, "get-user", user_name=USER)
    policy = optional(aws, "get-policy", policy_arn=policy_arn)
    if user:
        owned(aws.call("iam", "list-user-tags", user_name=USER).get("Tags", []), "user", adopt)
        if user["User"].get("PermissionsBoundary"):
            raise ValueError("Existing user has a permissions boundary; review it explicitly before continuing.")
        if optional(aws, "get-login-profile", user_name=USER):
            raise ValueError("Existing user has Console credentials; this bootstrap expects a CLI-only user.")
        if aws.call("iam", "list-groups-for-user", user_name=USER).get("Groups"):
            raise ValueError("Existing user has group memberships; review inherited permissions before continuing.")
        if aws.call("iam", "list-user-policies", user_name=USER).get("PolicyNames"):
            raise ValueError("Existing user has inline policies; review them before continuing.")
        attached = aws.call("iam", "list-attached-user-policies", user_name=USER).get("AttachedPolicies", [])
        if any(p["PolicyArn"] != policy_arn for p in attached):
            raise ValueError("Existing user has unrelated managed policies; no permissions were changed.")
    if policy:
        owned(aws.call("iam", "list-policy-tags", policy_arn=policy_arn).get("Tags", []), "policy", adopt)
        entities = aws.call("iam", "list-entities-for-policy", policy_arn=policy_arn)
        if entities.get("PolicyGroups") or entities.get("PolicyRoles") or any(u["UserName"] != USER for u in entities.get("PolicyUsers", [])):
            raise ValueError("Deployment policy is shared with other identities; refusing to modify it.")
        if policy["Policy"].get("PermissionsBoundaryUsageCount", 0):
            raise ValueError("Deployment policy is in use as a permissions boundary; refusing to modify it.")
    return user, policy


def apply(aws, account, document, adopt=False):
    arn = f"arn:aws:iam::{account}:policy/{POLICY}"
    user, policy = preflight(aws, account, arn, adopt)
    tags = [{"Key": key, "Value": value} for key, value in OWNER.items()]
    # Read and validate all existing policy state before making any IAM changes.
    changed = False
    if policy:
        current = aws.call("iam", "get-policy-version", policy_arn=arn,
                           version_id=policy["Policy"]["DefaultVersionId"])["PolicyVersion"]["Document"]
        changed = current != document
        if changed and len(aws.call("iam", "list-policy-versions", policy_arn=arn)["Versions"]) >= 5:
            raise ValueError("Policy has five versions. Review/delete an obsolete nondefault version in IAM, then rerun; no versions deleted automatically.")
    if adopt:
        # Every ownership/conflicting-permission/shared-policy check above passed first.
        if user:
            aws.call("iam", "tag-user", user_name=USER, tags=tags)
        if policy:
            aws.call("iam", "tag-policy", policy_arn=arn, tags=tags)
    if not policy:
        aws.call("iam", "create-policy", policy_name=POLICY, policy_document=document,
                 description="Trusted operator for Sankalpa deployment and migration", tags=tags)
        print("Created policy:", arn)
    elif changed:
        aws.call("iam", "create-policy-version", policy_arn=arn, policy_document=document, set_as_default=True)
        print("Updated deployment policy default version.")
    else:
        print("Deployment policy already matches.")
    if not user:
        aws.call("iam", "create-user", user_name=USER, tags=tags)
        print("Created CLI-only user:", USER)
    for attempt in range(6):
        try:
            aws.call("iam", "attach-user-policy", user_name=USER, policy_arn=arn)
            break
        except AwsError as error:
            if error.code != "NoSuchEntity" or attempt == 5:
                raise
            time.sleep(2)
    for attempt in range(6):
        attached = aws.call("iam", "list-attached-user-policies", user_name=USER).get("AttachedPolicies", [])
        if any(item["PolicyArn"] == arn for item in attached):
            break
        if attempt == 5:
            raise ValueError("Attachment not yet visible; rerun after IAM propagation. Owned resources are safe to reuse.")
        time.sleep(2)
    print("Verified policy attachment to:", f"arn:aws:iam::{account}:user/{USER}")
    if not adopt:
        print("IAM-only setup complete. Use --complete locally to configure credentials and verify live access.")


def retry_read(action):
    """Bounded retry for new IAM policy/key propagation; never retries a key creation."""
    for attempt in range(8):
        try:
            return action()
        except AwsError as error:
            if error.code not in {"AccessDenied", "AccessDeniedException", "InvalidClientTokenId",
                                  "UnrecognizedClientException", "InvalidAccessKeyId"} or attempt == 7:
                raise
            time.sleep(2)


def private_write(path, content, exclusive=False):
    """Write with private permissions from creation, without following file symlinks."""
    path = Path(path)
    if path.is_symlink():
        raise ValueError("Refusing to write a symbolic-link credential/config file.")
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    if exclusive:
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        try:
            with os.fdopen(fd, "w") as file:
                file.write(content)
                file.flush()
                os.fsync(file.fileno())
        except BaseException:
            path.unlink(missing_ok=True)
            raise
        return
    fd, temporary = tempfile.mkstemp(prefix=".sankalpa-", dir=path.parent)
    try:
        with os.fdopen(fd, "w") as file:
            file.write(content)
            file.flush()
            os.fsync(file.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def read_ini(path):
    parser = configparser.RawConfigParser()
    try:
        if Path(path).is_file():
            parser.read(path)
    except configparser.Error:
        raise ValueError("An AWS profile file is malformed; its contents were omitted to protect credentials.") from None
    return parser


def section_text(original, section, values):
    """Replace only the named section; keep all other profile bytes unchanged."""
    lines = original.splitlines(keepends=True)
    start = end = None
    for index, line in enumerate(lines):
        match = re.match(r"^\s*\[([^\]]+)\]\s*(?:[#;].*)?$", line.strip())
        if match:
            if start is not None:
                end = index
                break
            if match.group(1) == section:
                start = index
    block = "[" + section + "]\n" + "".join(k + " = " + v + "\n" for k, v in values.items()) + "\n"
    if start is None:
        return original + ("\n" if original and not original.endswith("\n\n") else "") + block
    return "".join(lines[:start]) + block + "".join(lines[end:]) if end is not None else "".join(lines[:start]) + block


def check_local_paths(env_file, credentials, config, state):
    env_file, credentials, config, state = map(Path, (env_file, credentials, config, state))
    if not env_file.is_file() or env_file.is_symlink():
        raise ValueError("Run --complete from your local repository with backend/.env.prod present as a regular file.")
    paths = (env_file, credentials, config, state)
    if any(p.is_symlink() or (p.exists() and not p.is_file()) for p in paths):
        raise ValueError("Setup paths must be regular files, not directories or symbolic links.")
    if len({p.resolve() for p in paths}) != 4:
        raise ValueError("Configuration, credentials, environment, and recovery paths must be distinct.")
    repository = Path(__file__).resolve().parents[2]
    for path in (credentials, config, state):
        if path.resolve().is_relative_to(repository):
            raise ValueError("AWS credentials/configuration must be stored outside the repository.")
        # Read/parse before creating an AWS key so malformed local files fail early.
        if path in (credentials, config):
            read_ini(path)


def login_admin(region, profile, admin_user, account):
    if profile in {"default", USER}:
        raise ValueError("Use a separate administrator profile; default and deployment profiles are preserved.")
    if not shutil.which("aws"):
        raise ValueError("Install AWS CLI v2.32.0 or newer before running complete setup.")
    version = subprocess.run(["aws", "--version"], capture_output=True, text=True, check=True).stdout
    match = re.search(r"aws-cli/(\d+)\.(\d+)\.(\d+)", version)
    if not match or tuple(map(int, match.groups())) < (2, 32, 0):
        raise ValueError("Full setup needs AWS CLI v2.32.0 or newer for browser login.")
    admin = AwsCLI(region, profile)
    try:
        identity = admin.call("sts", "get-caller-identity")
        if identity["Arn"].endswith(":user/" + admin_user):
            return admin
        raise ValueError("The administrator profile is already authenticated as another identity; it was not overwritten.")
    except AwsError:
        pass
    print("Browser sign-in: select account " + account + " and IAM administrator " + admin_user + ".", flush=True)
    print("Use your existing Console password and MFA in the browser. No SSO session name or access keys are requested.", flush=True)
    result = subprocess.run(["aws", "login", "--profile", profile, "--region", region, "--no-cli-pager"],
                            env=dict(os.environ, AWS_PAGER="", AWS_CLI_AUTO_PROMPT="off",
                                     AWS_IGNORE_CONFIGURED_ENDPOINT_URLS="true"))
    if result.returncode:
        raise ValueError("Administrator browser login failed. The IAM administrator needs SignInLocalDevelopmentAccess (or equivalent signin permissions).")
    identity = admin.call("sts", "get-caller-identity")
    if not identity["Arn"].endswith(":user/" + admin_user):
        raise ValueError("Browser login selected a different administrator identity; no IAM changes made.")
    return admin


def install_credentials(admin, account, region, profile, credentials, config, state):
    """Reuse an active locally stored key, or create one recoverably. Never rotate other keys."""
    metadata = admin.call("iam", "list-access-keys", user_name=USER)["AccessKeyMetadata"]
    active = {key["AccessKeyId"] for key in metadata if key["Status"] == "Active"}
    stored = read_ini(credentials)
    saved = dict(stored.items(profile)) if stored.has_section(profile) else {}
    pending = None
    if state.exists():
        if state.stat().st_mode & 0o077:
            raise ValueError("Recovery credentials file must have mode 600; no credentials were displayed.")
        pending = json.loads(state.read_text())
        if pending.get("Account") != account or pending.get("UserName") != USER:
            raise ValueError("Recovery file belongs to another account/user; refusing to use it.")
        if pending.get("AccessKeyId") not in active:
            raise ValueError("Saved recovery key is no longer active; inspect the key state before retrying.")
    key = None
    if saved.get("aws_access_key_id") in active and saved.get("aws_secret_access_key"):
        key = {"AccessKeyId": saved["aws_access_key_id"], "SecretAccessKey": saved["aws_secret_access_key"]}
        print("Reusing the active deployment key already stored locally.")
    elif pending:
        key = pending
        print("Resuming saved deployment credential setup.")
    elif saved:
        raise ValueError("The deployment profile already contains different/stale credentials; no existing credentials or keys were replaced.")
    else:
        if len(metadata) >= 2:
            raise ValueError("The deployment user already has two keys and no matching saved local key. No keys were deleted; resolve the existing keys before retrying.")
        # The recovery path is tested for write access before issuing a new key.
        state.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        fd, probe = tempfile.mkstemp(prefix=".write-check-", dir=state.parent)
        os.close(fd); os.unlink(probe)
        key = admin.call("iam", "create-access-key", user_name=USER)["AccessKey"]
        record = {"Account": account, "UserName": USER, "AccessKeyId": key["AccessKeyId"], "SecretAccessKey": key["SecretAccessKey"]}
        try:
            private_write(state, json.dumps(record), exclusive=True)
        except (OSError, ValueError):
            # Only the key created by this invocation can be removed on a failed initial save.
            try:
                admin.call("iam", "delete-access-key", user_name=USER, access_key_id=key["AccessKeyId"])
            except AwsError:
                raise ValueError("Credential save and new-key cleanup failed. Review the deployment user's newest key in IAM before retrying.") from None
            raise ValueError("Credential save failed; the newly created key was removed. Existing keys were untouched.") from None
        print("Created a deployment key and saved its recovery record privately; key values are hidden.")
    for path, section, values in (
        (config, "profile " + profile, {"region": region, "output": "json"}),
        (credentials, profile, {"aws_access_key_id": key["AccessKeyId"], "aws_secret_access_key": key["SecretAccessKey"]}),
    ):
        original = path.read_text() if path.exists() else ""
        if original:
            backup = path.with_name(path.name + ".before-sankalpa-" + uuid.uuid4().hex + ".bak")
            private_write(backup, original, exclusive=True)
        private_write(path, section_text(original, section, values))
    deployer = AwsCLI(region, profile)
    identity = retry_read(lambda: deployer.call("sts", "get-caller-identity"))
    if identity["Account"] != account or identity["Arn"] != f"arn:aws:iam::{account}:user/{USER}":
        raise ValueError("Installed deployment credentials resolved to an unexpected identity; recovery record retained.")
    if state.exists():
        state.unlink()
    print("Verified local deployment identity; credentials are stored with mode 600 under the AWS profile.")
    return deployer


def verify_access(admin, deployer, account, region):
    user_arn = f"arn:aws:iam::{account}:user/{USER}"
    cases = [
        (["cloudformation:DescribeStacks", "cloudformation:CreateChangeSet", "cloudformation:ExecuteChangeSet", "cloudformation:DeleteStack"], f"arn:aws:cloudformation:{region}:{account}:stack/sankalpa-prod-foundation/check", []),
        (["dynamodb:DescribeTable", "dynamodb:GetItem", "dynamodb:Query", "dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:DeleteItem", "dynamodb:CreateTable", "dynamodb:UpdateTable", "dynamodb:UpdateTimeToLive", "dynamodb:UpdateContinuousBackups"], f"arn:aws:dynamodb:{region}:{account}:table/sankalpa-prod", []),
        (["lambda:CreateFunction", "lambda:GetFunction", "lambda:PublishVersion", "lambda:CreateAlias", "lambda:CreateFunctionUrlConfig", "lambda:PutFunctionConcurrency"], f"arn:aws:lambda:{region}:{account}:function:sankalpa-prod", []),
        (["ecr:CreateRepository", "ecr:PutImage", "ecr:InitiateLayerUpload", "ecr:UploadLayerPart", "ecr:CompleteLayerUpload", "ecr:SetRepositoryPolicy"], f"arn:aws:ecr:{region}:{account}:repository/sankalpa-prod", []),
        (["logs:CreateLogGroup", "logs:PutRetentionPolicy", "logs:FilterLogEvents"], f"arn:aws:logs:{region}:{account}:log-group:/aws/lambda/sankalpa-prod", []),
        (["iam:CreateRole", "iam:PutRolePolicy", "iam:GetRole", "iam:ListRoleTags", "iam:PassRole"], f"arn:aws:iam::{account}:role/sankalpa-prod-runtime", [{"ContextKeyName": "iam:PassedToService", "ContextKeyValues": ["lambda.amazonaws.com"], "ContextKeyType": "string"}]),
        (["lambda:GetAccountSettings", "lambda:ListFunctions", "ecr:GetAuthorizationToken"], "*", []),
    ]
    for actions, resource, context in cases:
        for attempt in range(8):
            result = retry_read(lambda: admin.call("iam", "simulate-principal-policy", policy_source_arn=user_arn,
                                                   action_names=actions, resource_arns=[resource], context_entries=context))
            decisions = result.get("EvaluationResults", [])
            if len(decisions) == len(actions) and all(item["EvalDecision"] == "allowed" for item in decisions):
                break
            if attempt == 7:
                raise ValueError("IAM simulation denied required deployment actions for " + resource + ". No practice data was written.")
            time.sleep(2)
    try:
        stack = retry_read(lambda: deployer.call("cloudformation", "describe-stacks", stack_name="sankalpa-prod-foundation"))["Stacks"][0]
    except AwsError as error:
        if not error.missing_stack:
            raise
        print("IAM simulation passed. Foundation is absent; run backend setup before importing.")
        return
    tags = {tag["Key"]: tag["Value"] for tag in stack.get("Tags", [])}
    if tags.get("Project") != "Sankalpa" or tags.get("Environment") != "prod":
        stack = repair_foundation_tags(admin, stack)
    outputs = {item["OutputKey"]: item["OutputValue"] for item in stack.get("Outputs", [])}
    table = outputs.get("TableName")
    if not table or not table.startswith("sankalpa-prod"):
        raise ValueError("Foundation did not return the expected production table.")
    retry_read(lambda: deployer.call("dynamodb", "describe-table", table_name=table))
    retry_read(lambda: deployer.call("dynamodb", "query", table_name=table,
               key_condition_expression="PK = :pk", expression_attribute_values={":pk": {"S": "PRACTICE#default"}},
               select="COUNT", limit=1))
    print("Verified live CloudFormation and DynamoDB read access. Deployment/migration permissions passed IAM simulation.")


def repair_foundation_tags(admin, stack):
    """Adopt the exact Console-created foundation via a reviewed, tags-only change set."""
    name = "sankalpa-prod-foundation"
    expected_tags = {"Project": "Sankalpa", "Environment": "prod", "ManagedBy": "CloudFormation"}
    tags = {tag["Key"]: tag["Value"] for tag in stack.get("Tags", [])}
    if any(tags.get(key) not in (None, value) for key, value in expected_tags.items()):
        raise ValueError("Foundation has conflicting ownership tags; refusing to adopt it.")
    if stack.get("StackStatus") not in {"CREATE_COMPLETE", "UPDATE_COMPLETE", "UPDATE_ROLLBACK_COMPLETE"}:
        raise ValueError("Foundation is not in a stable state; ownership repair was not started.")
    parameters = {p["ParameterKey"]: p.get("ParameterValue", "") for p in stack.get("Parameters", [])}
    if parameters != {"ResourcePrefix": "sankalpa", "Environment": "prod", "RestoredTableName": ""}:
        raise ValueError("Foundation parameters differ from the original production setup; refusing automatic adoption.")
    template = Path(__file__).resolve().parents[2] / "infra/foundation.yaml"
    body = admin.call("cloudformation", "get-template", stack_name=name, template_stage="Original")["TemplateBody"]
    if not isinstance(body, str) or body.replace("\r\n", "\n").strip() != template.read_text().replace("\r\n", "\n").strip():
        raise ValueError("Foundation template does not exactly match this repository; ownership needs explicit review.")
    expected = {"Practice": ("AWS::DynamoDB::Table", "sankalpa-prod"),
                "Images": ("AWS::ECR::Repository", "sankalpa-prod"),
                "Logs": ("AWS::Logs::LogGroup", "/aws/lambda/sankalpa-prod"),
                "Runtime": ("AWS::IAM::Role", "sankalpa-prod-runtime")}
    resources = admin.call("cloudformation", "list-stack-resources", stack_name=name)["StackResourceSummaries"]
    actual = {r["LogicalResourceId"]: (r["ResourceType"], r["PhysicalResourceId"]) for r in resources}
    if actual != expected:
        raise ValueError("Foundation resources differ from the expected production resources; no ownership changes made.")
    runtime_policy = admin.call("iam", "get-role-policy", role_name="sankalpa-prod-runtime",
                                policy_name="PracticeAndLogs")["PolicyDocument"]
    change = admin.call("cloudformation", "create-change-set", stack_name=name,
                       change_set_name="bootstrap-tags-" + uuid.uuid4().hex, change_set_type="UPDATE",
                       use_previous_template=True, capabilities=["CAPABILITY_NAMED_IAM"],
                       parameters=[{"ParameterKey": key, "UsePreviousValue": True} for key in parameters],
                       tags=[{"Key": key, "Value": value} for key, value in {**tags, **expected_tags}.items()])["Id"]
    for attempt in range(60):
        result = admin.call("cloudformation", "describe-change-set", change_set_name=change)
        if result["Status"] == "CREATE_COMPLETE":
            break
        if result["Status"] == "FAILED" or attempt == 59:
            raise ValueError("Foundation tag change set could not be prepared; inspect its events before retrying.")
        time.sleep(2)
    changed_resources = {item.get("ResourceChange", {}).get("LogicalResourceId"): item.get("ResourceChange", {})
                         for item in result.get("Changes", [])}
    for item in result.get("Changes", []):
        resource = item.get("ResourceChange", {})
        safe = (resource.get("LogicalResourceId") in expected and resource.get("Action") == "Modify"
                and resource.get("Replacement", "False") == "False"
                and set(resource.get("Scope", [])) <= {"Tags", "Properties"})
        for detail in resource.get("Details", []):
            target = detail.get("Target", {})
            tag_change = target.get("Attribute") == "Tags" or (target.get("Attribute") == "Properties" and target.get("Name") == "Tags")
            # CloudFormation marks policy GetAtt expressions dynamic when a referenced
            # resource receives tags, even though that resource's ARN stays unchanged.
            reference = detail.get("CausingEntity", "")
            dependency = changed_resources.get(reference.partition(".")[0], {})
            stable_reference = (resource.get("LogicalResourceId") == "Runtime"
                and target.get("Attribute") == "Properties" and target.get("Name") == "Policies"
                and detail.get("Evaluation") == "Dynamic" and detail.get("ChangeSource") == "ResourceAttribute"
                and reference in {"Logs.Arn", "Practice.Arn"}
                and dependency.get("Action") == "Modify" and dependency.get("Replacement") == "False"
                and set(dependency.get("Scope", [])) == {"Tags"}
                and all(d.get("Target", {}).get("Attribute") == "Tags" for d in dependency.get("Details", [])))
            safe = safe and (tag_change or stable_reference)
        if not safe:
            admin.call("cloudformation", "delete-change-set", change_set_name=change)
            raise ValueError("Ownership repair would change more than tags; the change set was not executed.")
    print("Verified exact foundation template/resources; applying its missing ownership tags only.", flush=True)
    admin.call("cloudformation", "execute-change-set", change_set_name=change)
    for attempt in range(90):
        updated = admin.call("cloudformation", "describe-stacks", stack_name=name)["Stacks"][0]
        state = updated["StackStatus"]
        updated_tags = {tag["Key"]: tag["Value"] for tag in updated.get("Tags", [])}
        if state == "UPDATE_COMPLETE" and all(updated_tags.get(key) == value for key, value in expected_tags.items()):
            current_policy = admin.call("iam", "get-role-policy", role_name="sankalpa-prod-runtime",
                                        policy_name="PracticeAndLogs")["PolicyDocument"]
            if current_policy != runtime_policy:
                raise ValueError("Ownership tags updated, but the runtime policy differs from its pre-update snapshot; inspect it before proceeding.")
            print("Foundation ownership tags are configured and verified.")
            return updated
        if state.endswith(("FAILED", "ROLLBACK_COMPLETE")) or attempt == 89:
            raise ValueError("Foundation tag update did not complete; inspect CloudFormation events.")
        time.sleep(2)


@contextlib.contextmanager
def setup_lock(path):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd = os.open(path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise ValueError("Another complete setup is running; wait for it before retrying.") from None
        yield
    finally:
        os.close(fd)


def complete(args, document):
    profile = USER
    if args.admin_profile == profile:
        raise ValueError("Administrator and deployment profiles must be separate.")
    env_file = args.env_file.expanduser().absolute()
    credentials = Path(os.environ.get("AWS_SHARED_CREDENTIALS_FILE", str(Path.home() / ".aws/credentials"))).expanduser()
    config = Path(os.environ.get("AWS_CONFIG_FILE", str(Path.home() / ".aws/config"))).expanduser()
    state = Path.home() / ".aws/sankalpa-bootstrap" / (args.account_id + "-pending-key.json")
    check_local_paths(env_file, credentials, config, state)
    with setup_lock(state.with_suffix(".lock")):
        complete_locked(args, document, profile, env_file, credentials, config, state)


def complete_locked(args, document, profile, env_file, credentials, config, state):
    print("[1/5] Checking local configuration and administrator authentication.", flush=True)
    original = env_file.read_text()
    values = {}
    for line in original.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        key, separator, value = line.partition("=")
        key = key.strip()
        if not separator or not re.fullmatch(r"[A-Z][A-Z0-9_]*", key) or key in values:
            raise ValueError(".env.prod contains an invalid or duplicate assignment; no credentials were displayed.")
        values[key] = value.strip().strip("\"'")
    if values.get("DEPLOY_ACCOUNT_ID") != args.account_id or values.get("DEPLOY_REGION") != args.region:
        raise ValueError(".env.prod account/Region do not match this invocation; no AWS changes made.")
    existing = read_ini(config)
    section = "profile " + profile
    if existing.has_section(section) and any(existing.has_option(section, key) for key in ["role_arn", "sso_session", "sso_start_url", "credential_process", "login_session", "credential_source", "source_profile", "web_identity_token_file"]):
        raise ValueError("The deployment profile uses a different authentication mechanism; refusing to replace it.")
    for name, expected in {"DEPLOY_ACCOUNT_ID": args.account_id, "DEPLOY_REGION": args.region, "DEPLOY_AWS_PROFILE": profile}.items():
        if name in os.environ and os.environ[name] != expected:
            raise ValueError("A conflicting deployment environment override is set: " + name + ". Clear it before setup.")
    admin = login_admin(args.region, args.admin_profile or "sankalpa-bootstrap-admin", args.admin_user, args.account_id)
    print("[2/5] Configuring the dedicated deployment user and policy.", flush=True)
    apply(admin, args.account_id, document, adopt=True)
    print("[3/5] Configuring private local deployment credentials.", flush=True)
    deployer = install_credentials(admin, args.account_id, args.region, profile, credentials, config, state)
    print("[4/5] Verifying deployment permissions and live read access.", flush=True)
    verify_access(admin, deployer, args.account_id, args.region)
    print("[5/5] Updating the production environment profile selection.", flush=True)
    lines = original.splitlines(keepends=True)
    count = 0
    for index, line in enumerate(lines):
        if line.partition("=")[0].strip() == "DEPLOY_AWS_PROFILE":
            lines[index] = "DEPLOY_AWS_PROFILE=" + profile + "\n"; count += 1
    if count > 1:
        raise ValueError("Duplicate DEPLOY_AWS_PROFILE assignments; local profile is ready but .env.prod was not changed.")
    if not count:
        lines.append(("\n" if original and not original.endswith("\n") else "") + "DEPLOY_AWS_PROFILE=" + profile + "\n")
    if env_file.read_text() != original:
        raise ValueError(".env.prod changed during setup; profile is ready but concurrent edits were preserved.")
    private_write(env_file, "".join(lines))
    print("SETUP COMPLETE: user, policy, access key, local profile, .env.prod, and access checks are ready.")
    print("No database import or application deployment was run. Continue with backend db import and db validate.")


def main(argv=None, cli_factory=AwsCLI):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--account-id", required=True)
    parser.add_argument("--region", default="us-east-1")
    parser.add_argument("--admin-profile", help="Existing IAM administrator profile; omit in an administrator AWS CloudShell session")
    parser.add_argument("--admin-user", default="pswani1-admin", help="Expected IAM administrator user for browser login (default: pswani1-admin)")
    parser.add_argument("--env-file", type=Path, default=Path(__file__).resolve().parents[1] / ".env.prod")
    parser.add_argument("--policy-template", type=Path, default=DEFAULT_TEMPLATE)
    parser.add_argument("--policy-output", type=Path, help="Save the rendered nonsecret policy for Console review")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--plan", action="store_true", help="Default: render a plan without AWS calls")
    mode.add_argument("--apply", action="store_true", help="Create/update owned IAM resources and attach the deployment policy")
    mode.add_argument("--complete", action="store_true", help="Run locally: browser admin login, IAM setup/adoption, private credentials, local profile and live checks")
    args = parser.parse_args(argv)
    if not re.fullmatch(r"[\w+=,.@-]+", args.admin_user):
        raise ValueError("Invalid IAM administrator user name.")
    policy = render_policy(args.policy_template, args.account_id, args.region)
    if args.policy_output:
        output = args.policy_output.resolve()
        if output == args.policy_template.resolve() or output.exists():
            raise ValueError("Policy output already exists or points to the source template; choose a new output path.")
        with output.open("x") as file:
            file.write(json.dumps(policy, indent=2) + "\n")
        print("Rendered policy:", output)
    if args.complete:
        complete(args, policy)
        return
    if not args.apply:
        print("PLAN: no AWS calls. Create/reuse owned CLI-only user", USER)
        print("Attach policy:", f"arn:aws:iam::{args.account_id}:policy/{POLICY}")
        print("Region:", args.region)
        print("Use --complete on your Mac for the full setup, or --apply for IAM-only setup in CloudShell.")
        if not args.policy_output:
            print(json.dumps(policy, indent=2))
        return
    apply(cli_factory(args.region, args.admin_profile), args.account_id, policy)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, AwsError, OSError) as error:
        print("Error:", error, file=sys.stderr)
        sys.exit(1)
