import contextlib
import copy
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch
from types import SimpleNamespace

spec = importlib.util.spec_from_file_location("setup_aws_deployer", Path(__file__).parents[1] / "setup_aws_deployer.py")
setup = importlib.util.module_from_spec(spec)
spec.loader.exec_module(setup)
ACCOUNT = "123456789012"
ARN = f"arn:aws:iam::{ACCOUNT}:policy/SankalpaDeployer"
TAGS = [{"Key": k, "Value": v} for k, v in setup.OWNER.items()]
DOCUMENT = setup.render_policy(setup.DEFAULT_TEMPLATE, ACCOUNT, "us-east-1")
WRITES = {"create-user", "create-policy", "create-policy-version", "attach-user-policy"}


class FakeAWS:
    def __init__(self, existing=False):
        self.user = existing
        self.policy = existing
        self.account = ACCOUNT
        self.identity = f"arn:aws:sts::{ACCOUNT}:assumed-role/BootstrapAdmin/session"
        self.tags = copy.deepcopy(TAGS)
        self.document = copy.deepcopy(DOCUMENT)
        self.groups = []
        self.inline = []
        self.attached = [{"PolicyArn": ARN}] if existing else []
        self.shared = []
        self.boundary = False
        self.console = False
        self.versions = [{"VersionId": "v1"}]
        self.calls = []
        self.attach_delay = 0

    def call(self, service, operation, **kwargs):
        self.calls.append((service, operation, kwargs))
        if operation == "get-caller-identity": return {"Account": self.account, "Arn": self.identity}
        if operation in {"get-user", "get-policy"}:
            if not getattr(self, "user" if operation == "get-user" else "policy"):
                raise setup.AwsError(operation, "NoSuchEntity")
            if operation == "get-user": return {"User": {"PermissionsBoundary": {} } if not self.boundary else {"PermissionsBoundary": {"PermissionsBoundaryArn": "boundary"}}}
            return {"Policy": {"DefaultVersionId": "v1"}}
        if operation in {"list-user-tags", "list-policy-tags"}: return {"Tags": self.tags}
        if operation == "get-login-profile":
            if self.console: return {"LoginProfile": {"UserName": setup.USER}}
            raise setup.AwsError(operation, "NoSuchEntity")
        if operation == "list-groups-for-user": return {"Groups": self.groups}
        if operation == "list-user-policies": return {"PolicyNames": self.inline}
        if operation == "list-attached-user-policies": return {"AttachedPolicies": self.attached}
        if operation == "list-entities-for-policy": return {"PolicyUsers": self.shared}
        if operation == "get-policy-version": return {"PolicyVersion": {"Document": self.document}}
        if operation == "list-policy-versions": return {"Versions": self.versions}
        if operation == "create-policy":
            self.policy = True; self.document = kwargs["policy_document"]; return {}
        if operation == "create-policy-version":
            self.document = kwargs["policy_document"]; return {}
        if operation == "create-user": self.user = True; return {}
        if operation == "attach-user-policy":
            if self.attach_delay:
                self.attach_delay -= 1
                raise setup.AwsError(operation, "NoSuchEntity")
            self.attached = [{"PolicyArn": kwargs["policy_arn"]}]; return {}
        raise AssertionError("Unexpected AWS operation: " + operation)


class BootstrapTests(unittest.TestCase):
    def apply(self, aws):
        with contextlib.redirect_stdout(io.StringIO()), patch.object(setup.time, "sleep"):
            setup.apply(aws, ACCOUNT, DOCUMENT)

    def assert_readonly(self, aws):
        self.assertFalse(any(op in WRITES for _, op, _ in aws.calls))

    def test_plan_is_default_and_never_constructs_aws_client(self):
        with contextlib.redirect_stdout(io.StringIO()) as out:
            setup.main(["--account-id", ACCOUNT], cli_factory=lambda *a: self.fail("AWS contacted"))
        self.assertIn("PLAN: no AWS calls", out.getvalue())
        self.assertNotIn("ACCOUNT_ID", out.getvalue())

    def test_plan_output_is_valid_and_cannot_overwrite(self):
        with tempfile.TemporaryDirectory() as directory, contextlib.redirect_stdout(io.StringIO()):
            output = Path(directory) / "policy.json"
            setup.main(["--account-id", ACCOUNT, "--policy-output", str(output)])
            self.assertEqual(json.loads(output.read_text()), DOCUMENT)
            with self.assertRaises(ValueError):
                setup.main(["--account-id", ACCOUNT, "--policy-output", str(output)])

    def test_bad_account_and_region_fail_before_aws(self):
        for account, region in [("not-an-account", "us-east-1"), (ACCOUNT, "us-gov-west-1")]:
            with self.assertRaises(ValueError):
                setup.render_policy(setup.DEFAULT_TEMPLATE, account, region)

    def test_account_mismatch_does_not_mutate(self):
        aws = FakeAWS(); aws.account = "999999999999"
        with self.assertRaisesRegex(ValueError, "account does not match"): self.apply(aws)
        self.assert_readonly(aws)

    def test_root_and_self_bootstrap_are_refused(self):
        for identity in [f"arn:aws:iam::{ACCOUNT}:root", f"arn:aws:iam::{ACCOUNT}:user/sankalpa-deployer"]:
            aws = FakeAWS(); aws.identity = identity
            with self.assertRaises(ValueError): self.apply(aws)
            self.assert_readonly(aws)

    def test_new_resources_are_tagged_and_policy_attached_without_keys(self):
        aws = FakeAWS(); self.apply(aws)
        operations = [op for _, op, _ in aws.calls]
        self.assertTrue(aws.user and aws.policy)
        self.assertEqual(aws.attached, [{"PolicyArn": ARN}])
        for _, operation, args in aws.calls:
            if operation in {"create-user", "create-policy"}: self.assertEqual(args["tags"], TAGS)
        self.assertEqual([op for op in operations if op in WRITES], ["create-policy", "create-user", "attach-user-policy"])

    def test_matching_rerun_does_not_recreate_or_version_resources(self):
        aws = FakeAWS(existing=True); self.apply(aws)
        self.assertEqual([op for _, op, _ in aws.calls if op in WRITES], ["attach-user-policy"])

    def test_unowned_existing_user_or_policy_is_not_adopted(self):
        for user, policy in [(True, False), (False, True)]:
            aws = FakeAWS(); aws.user = user; aws.policy = policy; aws.tags = []
            with self.assertRaisesRegex(ValueError, "ownership tags"): self.apply(aws)
            self.assert_readonly(aws)

    def test_extra_permissions_console_or_boundary_require_review(self):
        cases = {"groups": [{"GroupName": "Administrators"}], "inline": ["Extra"],
                 "attached": [{"PolicyArn": "arn:aws:iam::aws:policy/AdministratorAccess"}],
                 "console": True, "boundary": True}
        for field, value in cases.items():
            aws = FakeAWS(existing=True); setattr(aws, field, value)
            with self.assertRaises(ValueError): self.apply(aws)
            self.assert_readonly(aws)

    def test_shared_policy_is_not_modified(self):
        aws = FakeAWS(existing=True); aws.shared = [{"UserName": "synology-backup"}]
        with self.assertRaisesRegex(ValueError, "shared"): self.apply(aws)
        self.assert_readonly(aws)

    def test_policy_update_is_versioned_and_keeps_history(self):
        aws = FakeAWS(existing=True); aws.document = {"Version": "2012-10-17", "Statement": []}
        self.apply(aws)
        updates = [args for _, op, args in aws.calls if op == "create-policy-version"]
        self.assertEqual(len(updates), 1)
        self.assertIs(updates[0]["set_as_default"], True)
        self.assertFalse(any(op == "delete-policy-version" for _, op, _ in aws.calls))

    def test_version_limit_fails_before_any_write(self):
        aws = FakeAWS(existing=True); aws.document = {}; aws.versions *= 5
        with self.assertRaisesRegex(ValueError, "five versions"): self.apply(aws)
        self.assert_readonly(aws)

    def test_new_iam_resource_propagation_retries_attachment(self):
        aws = FakeAWS(); aws.attach_delay = 2; self.apply(aws)
        self.assertEqual(sum(op == "attach-user-policy" for _, op, _ in aws.calls), 3)
        self.assertEqual(aws.attached, [{"PolicyArn": ARN}])

    def test_cli_uses_boolean_flags_and_explicit_profile_without_a_shell(self):
        result = subprocess.CompletedProcess([], 0, "{}", "")
        with patch.object(setup.shutil, "which", return_value="/usr/bin/aws"), patch.object(setup.subprocess, "run", return_value=result) as run:
            client = setup.AwsCLI("us-east-1", "bootstrap-admin")
            client.call("iam", "create-policy-version", policy_arn=ARN, policy_document=DOCUMENT, set_as_default=True)
        args = run.call_args.args[0]
        self.assertIn("--set-as-default", args)
        self.assertEqual(args[args.index("--profile") + 1], "bootstrap-admin")
        self.assertEqual(json.loads(args[args.index("--policy-document") + 1]), DOCUMENT)
        self.assertNotIn("true", args)
        self.assertNotIn("shell", run.call_args.kwargs)

    def test_cli_failure_does_not_echo_arbitrary_stderr(self):
        result = subprocess.CompletedProcess([], 1, "", "Error (AccessDenied) when calling GetUser: private-detail")
        with patch.object(setup.shutil, "which", return_value="/usr/bin/aws"), patch.object(setup.subprocess, "run", return_value=result):
            client = setup.AwsCLI("us-east-1")
            with self.assertRaises(setup.AwsError) as caught: client.call("iam", "get-user", user_name=setup.USER)
        self.assertEqual(caught.exception.code, "AccessDenied")
        self.assertNotIn("private-detail", str(caught.exception))

    def test_rendered_runtime_policy_is_scoped_and_cannot_manage_users(self):
        statements = {s["Sid"]: s for s in DOCUMENT["Statement"]}
        self.assertEqual(statements["PassRuntimeRolesOnlyToLambda"]["Condition"]["StringEquals"]["iam:PassedToService"], "lambda.amazonaws.com")
        self.assertEqual(statements["SankalpaStacks"]["Resource"], f"arn:aws:cloudformation:us-east-1:{ACCOUNT}:stack/sankalpa-*/*")
        roles = statements["ManageOnlyRuntimeRoles"]
        self.assertNotIn("iam:CreateUser", roles["Action"])
        self.assertNotIn("iam:CreateAccessKey", roles["Action"])
        self.assertIn("iam:ListRoleTags", roles["Action"])
        self.assertIn(f"arn:aws:logs:us-east-1:{ACCOUNT}:log-group:/aws/lambda/sankalpa-*:*", statements["SankalpaResources"]["Resource"])


class CompleteAdmin(FakeAWS):
    def __init__(self, existing=False):
        super().__init__(existing)
        self.keys = []
        self.denied = False

    def call(self, service, operation, **kwargs):
        if operation in {"tag-user", "tag-policy", "list-access-keys", "create-access-key", "delete-access-key", "simulate-principal-policy"}:
            self.calls.append((service, operation, kwargs))
            if operation in {"tag-user", "tag-policy"}: self.tags = copy.deepcopy(kwargs["tags"]); return {}
            if operation == "list-access-keys": return {"AccessKeyMetadata": self.keys}
            if operation == "create-access-key":
                self.keys.append({"AccessKeyId": "TEST_ACCESS_KEY_00000", "Status": "Active"})
                return {"AccessKey": {"AccessKeyId": "TEST_ACCESS_KEY_00000", "SecretAccessKey": "TEST_ONLY_SECRET_VALUE"}}
            if operation == "delete-access-key":
                self.keys = [key for key in self.keys if key["AccessKeyId"] != kwargs["access_key_id"]]; return {}
            return {"EvaluationResults": [{"EvalActionName": action, "EvalDecision": "explicitDeny" if self.denied else "allowed"} for action in kwargs["action_names"]]}
        return super().call(service, operation, **kwargs)


class CompleteDeployer:
    def __init__(self): self.calls = []; self.missing = False

    def call(self, service, operation, **kwargs):
        self.calls.append((service, operation, kwargs))
        if operation == "get-caller-identity": return {"Account": ACCOUNT, "Arn": f"arn:aws:iam::{ACCOUNT}:user/{setup.USER}"}
        if operation == "describe-stacks":
            if self.missing: raise setup.AwsError(operation, "ValidationError", missing_stack=True)
            return {"Stacks": [{"Tags": [{"Key": "Project", "Value": "Sankalpa"}, {"Key": "Environment", "Value": "prod"}], "Outputs": [{"OutputKey": "TableName", "OutputValue": "sankalpa-prod"}]}]}
        if operation in {"describe-table", "query"}: return {}
        raise AssertionError("Unexpected deployment operation: " + operation)


class FoundationAdmin:
    def __init__(self):
        self.stack = {"StackStatus": "CREATE_COMPLETE", "Tags": [], "Parameters": [
            {"ParameterKey": key, "ParameterValue": value} for key, value in
            {"ResourcePrefix": "sankalpa", "Environment": "prod", "RestoredTableName": ""}.items()]}
        self.template = (setup.DEFAULT_TEMPLATE.parent / "foundation.yaml").read_text()
        self.changes = [{"ResourceChange": {"LogicalResourceId": "Practice", "Action": "Modify", "Replacement": "False", "Scope": ["Tags"], "Details": [{"Target": {"Attribute": "Tags"}}]}}]
        self.calls = []

    def call(self, service, operation, **kwargs):
        self.calls.append((service, operation, kwargs))
        if operation == "get-template": return {"TemplateBody": self.template}
        if operation == "get-role-policy": return {"PolicyDocument": {"Version": "2012-10-17", "Statement": []}}
        if operation == "list-stack-resources":
            return {"StackResourceSummaries": [
                {"LogicalResourceId": name, "ResourceType": kind, "PhysicalResourceId": physical} for name, kind, physical in [
                    ("Practice", "AWS::DynamoDB::Table", "sankalpa-prod"), ("Images", "AWS::ECR::Repository", "sankalpa-prod"),
                    ("Logs", "AWS::Logs::LogGroup", "/aws/lambda/sankalpa-prod"), ("Runtime", "AWS::IAM::Role", "sankalpa-prod-runtime")]]}
        if operation == "create-change-set": self.tags = kwargs["tags"]; return {"Id": "test-change"}
        if operation == "describe-change-set": return {"Status": "CREATE_COMPLETE", "Changes": self.changes}
        if operation == "delete-change-set": return {}
        if operation == "execute-change-set": self.stack.update(StackStatus="UPDATE_COMPLETE", Tags=self.tags); return {}
        if operation == "describe-stacks": return {"Stacks": [self.stack]}
        raise AssertionError(operation)


class FoundationOwnershipTests(unittest.TestCase):
    def test_direct_runtime_policy_change_is_not_executed(self):
        admin = FoundationAdmin()
        admin.changes = [{"ResourceChange": {"LogicalResourceId": "Runtime", "Action": "Modify", "Replacement": "False", "Scope": ["Properties"], "Details": [
            {"Target": {"Attribute": "Properties", "Name": "Policies"}, "Evaluation": "Static", "ChangeSource": "DirectModification"}]}}]
        with self.assertRaisesRegex(ValueError, "more than tags"): setup.repair_foundation_tags(admin, admin.stack)
        self.assertFalse(any(op == "execute-change-set" for _, op, _ in admin.calls))

    def test_tag_dependent_dynamic_arn_recalculation_is_allowed(self):
        admin = FoundationAdmin()
        admin.changes.append({"ResourceChange": {"LogicalResourceId": "Runtime", "Action": "Modify", "Replacement": "False", "Scope": ["Properties", "Tags"], "Details": [
            {"Target": {"Attribute": "Tags"}},
            {"Target": {"Attribute": "Properties", "Name": "Policies"}, "Evaluation": "Dynamic", "ChangeSource": "ResourceAttribute", "CausingEntity": "Practice.Arn"}]}})
        with contextlib.redirect_stdout(io.StringIO()): setup.repair_foundation_tags(admin, admin.stack)
        self.assertTrue(any(op == "execute-change-set" for _, op, _ in admin.calls))

    def test_exact_console_foundation_is_adopted_with_tags_only(self):
        admin = FoundationAdmin()
        with contextlib.redirect_stdout(io.StringIO()): result = setup.repair_foundation_tags(admin, admin.stack)
        self.assertEqual(result["StackStatus"], "UPDATE_COMPLETE")
        request = next(args for _, op, args in admin.calls if op == "create-change-set")
        self.assertIs(request["use_previous_template"], True)
        self.assertTrue(all(p["UsePreviousValue"] for p in request["parameters"]))
        self.assertNotIn("template_body", request)
        self.assertEqual({tag["Key"]: tag["Value"] for tag in result["Tags"]}["Project"], "Sankalpa")

    def test_different_template_is_not_adopted(self):
        admin = FoundationAdmin(); admin.template = "Different template"
        with self.assertRaisesRegex(ValueError, "exactly match"): setup.repair_foundation_tags(admin, admin.stack)
        self.assertFalse(any(op == "create-change-set" for _, op, _ in admin.calls))

    def test_conflicting_owner_is_not_overwritten(self):
        admin = FoundationAdmin(); admin.stack["Tags"] = [{"Key": "Project", "Value": "Other"}]
        with self.assertRaisesRegex(ValueError, "conflicting"): setup.repair_foundation_tags(admin, admin.stack)
        self.assertFalse(admin.calls)

    def test_non_tag_change_set_is_deleted_without_execution(self):
        admin = FoundationAdmin()
        admin.changes[0]["ResourceChange"].update(Scope=["Properties"], Details=[{"Target": {"Attribute": "Properties", "Name": "BillingMode"}}])
        with self.assertRaisesRegex(ValueError, "more than tags"): setup.repair_foundation_tags(admin, admin.stack)
        operations = [op for _, op, _ in admin.calls]
        self.assertIn("delete-change-set", operations)
        self.assertNotIn("execute-change-set", operations)


class CompleteSetupTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.home = Path(self.directory.name)
        self.credentials = self.home / ".aws/credentials"
        self.config = self.home / ".aws/config"
        self.env = self.home / ".env.prod"
        self.env.write_text(f"DEPLOY_ACCOUNT_ID={ACCOUNT}\nDEPLOY_REGION=us-east-1\nDEPLOY_AWS_PROFILE=default\nSANKALPA_API_TOKEN=preserve-this-runtime-value\n")
        self.credentials.parent.mkdir()
        self.old_credentials = "[default]\naws_access_key_id = BACKUP_KEY\naws_secret_access_key = BACKUP_SECRET\n"
        self.credentials.write_text(self.old_credentials)
        self.config.write_text("[default]\nregion = us-east-1\noutput = json\n")
        self.args = SimpleNamespace(account_id=ACCOUNT, region="us-east-1", env_file=self.env, admin_profile=None, admin_user="pswani1-admin")
        self.admin = CompleteAdmin()
        self.deployer = CompleteDeployer()
        self.state = self.home / ".aws/sankalpa-bootstrap" / (ACCOUNT + "-pending-key.json")
        self.output = io.StringIO()

    def run_complete(self):
        with patch.object(setup.Path, "home", return_value=self.home), patch.dict(os.environ, {"AWS_CONFIG_FILE": str(self.config), "AWS_SHARED_CREDENTIALS_FILE": str(self.credentials)}, clear=True), patch.object(setup, "login_admin", return_value=self.admin), patch.object(setup, "AwsCLI", return_value=self.deployer), patch.object(setup.time, "sleep"), contextlib.redirect_stdout(self.output):
            setup.complete(self.args, DOCUMENT)

    def test_full_setup_preserves_backup_profile_and_never_prints_secret(self):
        self.run_complete()
        self.assertIn(self.old_credentials, self.credentials.read_text())
        self.assertIn("[sankalpa-deployer]", self.credentials.read_text())
        self.assertEqual(self.credentials.stat().st_mode & 0o777, 0o600)
        self.assertEqual(self.config.stat().st_mode & 0o777, 0o600)
        self.assertFalse(self.state.exists())
        self.assertIn("DEPLOY_AWS_PROFILE=sankalpa-deployer", self.env.read_text())
        self.assertIn("SANKALPA_API_TOKEN=preserve-this-runtime-value", self.env.read_text())
        self.assertNotIn("TEST_ONLY_SECRET_VALUE", self.output.getvalue())
        self.assertIn("SETUP COMPLETE", self.output.getvalue())
        self.assertTrue(any(op == "query" for _, op, _ in self.deployer.calls))
        self.assertFalse(any(op in {"put-item", "update-item", "delete-item"} for _, op, _ in self.deployer.calls))

    def test_complete_rerun_reuses_key(self):
        self.run_complete(); self.run_complete()
        self.assertEqual(sum(op == "create-access-key" for _, op, _ in self.admin.calls), 1)

    def test_complete_adopts_dedicated_untagged_resources(self):
        self.admin = CompleteAdmin(existing=True); self.admin.tags = []
        self.run_complete()
        self.assertEqual(self.admin.tags, TAGS)

    def test_shared_policy_is_not_adopted(self):
        self.admin = CompleteAdmin(existing=True); self.admin.tags = []; self.admin.shared = [{"UserName": "synology-backup"}]
        with self.assertRaisesRegex(ValueError, "shared"): self.run_complete()
        self.assertFalse(any(op in WRITES | {"tag-user", "tag-policy", "create-access-key"} for _, op, _ in self.admin.calls))

    def test_conflicting_project_ownership_is_not_adopted(self):
        self.admin = CompleteAdmin(existing=True); self.admin.tags = [{"Key": "Project", "Value": "Other"}]
        with self.assertRaisesRegex(ValueError, "ownership"): self.run_complete()
        self.assertFalse(any(op == "create-access-key" for _, op, _ in self.admin.calls))

    def test_two_unavailable_keys_are_not_deleted(self):
        self.admin.keys = [{"AccessKeyId": "OTHER1", "Status": "Active"}, {"AccessKeyId": "OTHER2", "Status": "Inactive"}]
        with self.assertRaisesRegex(ValueError, "two keys"): self.run_complete()
        self.assertFalse(any(op in {"create-access-key", "delete-access-key"} for _, op, _ in self.admin.calls))
        self.assertEqual(self.credentials.read_text(), self.old_credentials)

    def test_profile_write_failure_is_recoverable_without_another_key(self):
        real_write = setup.private_write
        def fail_credentials(path, *args, **kwargs):
            if Path(path) == self.credentials: raise OSError("simulated disk error")
            return real_write(path, *args, **kwargs)
        with patch.object(setup, "private_write", side_effect=fail_credentials):
            with self.assertRaises(OSError): self.run_complete()
        self.assertTrue(self.state.exists())
        self.assertEqual(self.state.stat().st_mode & 0o777, 0o600)
        self.run_complete()
        self.assertEqual(sum(op == "create-access-key" for _, op, _ in self.admin.calls), 1)
        self.assertFalse(self.state.exists())

    def test_failed_first_secret_save_cleans_up_only_new_key(self):
        real_write = setup.private_write
        def fail_state(path, *args, **kwargs):
            if Path(path) == self.state: raise OSError("simulated disk error")
            return real_write(path, *args, **kwargs)
        with patch.object(setup, "private_write", side_effect=fail_state):
            with self.assertRaisesRegex(ValueError, "newly created key was removed"): self.run_complete()
        self.assertFalse(self.admin.keys)
        deletions = [args["access_key_id"] for _, op, args in self.admin.calls if op == "delete-access-key"]
        self.assertEqual(deletions, ["TEST_ACCESS_KEY_00000"])

    def test_denied_simulation_never_reports_complete_or_writes_practice(self):
        self.admin.denied = True
        with self.assertRaisesRegex(ValueError, "simulation"): self.run_complete()
        self.assertNotIn("SETUP COMPLETE", self.output.getvalue())
        self.assertFalse(any(op == "query" for _, op, _ in self.deployer.calls))

    def test_missing_foundation_reports_required_next_operation(self):
        self.deployer.missing = True; self.run_complete()
        self.assertIn("Foundation is absent", self.output.getvalue())
        self.assertFalse(any(op == "query" for _, op, _ in self.deployer.calls))

    def test_duplicate_env_assignment_fails_before_aws(self):
        self.env.write_text(self.env.read_text() + "DEPLOY_AWS_PROFILE=duplicate\n")
        with self.assertRaisesRegex(ValueError, "duplicate"): self.run_complete()
        self.assertFalse(self.admin.calls)

    def test_foreign_deployment_auth_profile_is_not_replaced(self):
        self.config.write_text("[profile sankalpa-deployer]\nrole_arn = arn:aws:iam::123456789012:role/Other\n")
        with self.assertRaisesRegex(ValueError, "different authentication"): self.run_complete()
        self.assertFalse(self.admin.calls)

    def test_malformed_profile_errors_do_not_echo_contents(self):
        self.credentials.write_text("CREDENTIAL_VALUE_MUST_NOT_APPEAR")
        with self.assertRaises(ValueError) as caught: self.run_complete()
        self.assertNotIn("CREDENTIAL_VALUE_MUST_NOT_APPEAR", str(caught.exception))
        self.assertFalse(self.admin.calls)

    def test_login_uses_browser_instead_of_sso_or_key_prompts(self):
        admin = FakeAWS(); identity = {"Account": ACCOUNT, "Arn": f"arn:aws:iam::{ACCOUNT}:user/pswani1-admin"}
        results = [setup.AwsError("sts", "CLIError"), identity]
        with patch.object(setup.shutil, "which", return_value="aws"), patch.object(setup, "AwsCLI") as factory, patch.object(setup.subprocess, "run", side_effect=[subprocess.CompletedProcess([], 0, "aws-cli/2.38.1", ""), subprocess.CompletedProcess([], 0)]) as run, contextlib.redirect_stdout(self.output):
            factory.return_value.call.side_effect = results
            setup.login_admin("us-east-1", "sankalpa-bootstrap-admin", "pswani1-admin", ACCOUNT)
        command = run.call_args_list[1].args[0]
        self.assertEqual(command[1], "login")
        self.assertIn("--region", command)
        self.assertNotIn("sso", command)
        self.assertNotIn("capture_output", run.call_args_list[1].kwargs)

    def test_admin_login_does_not_overwrite_default_profile(self):
        with self.assertRaisesRegex(ValueError, "separate administrator"):
            setup.login_admin("us-east-1", "default", "pswani1-admin", ACCOUNT)

    def test_unsupported_cli_version_fails_before_login(self):
        with patch.object(setup.shutil, "which", return_value="aws"), patch.object(setup.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, "aws-cli/2.31.0", "")) as run:
            with self.assertRaisesRegex(ValueError, "2.32.0"):
                setup.login_admin("us-east-1", "sankalpa-bootstrap-admin", "pswani1-admin", ACCOUNT)
        self.assertEqual(run.call_count, 1)

    def test_concurrent_complete_setup_is_refused_before_aws(self):
        with setup.setup_lock(self.state.with_suffix(".lock")):
            with self.assertRaisesRegex(ValueError, "Another complete setup"): self.run_complete()
        self.assertFalse(self.admin.calls)

    def test_replacing_middle_profile_preserves_other_sections_exactly(self):
        before = "# original\n[default]\nregion=us-east-1\n\n"
        after = "[profile another]\nregion=eu-west-1\n# keep comment\n"
        old = before + "[profile sankalpa-deployer]\nregion=us-west-1\n\n" + after
        updated = setup.section_text(old, "profile sankalpa-deployer", {"region": "us-east-1"})
        self.assertTrue(updated.startswith(before))
        self.assertTrue(updated.endswith(after))

    def test_failed_secret_save_does_not_remove_preexisting_key(self):
        self.admin.keys = [{"AccessKeyId": "PREEXISTING_KEY", "Status": "Active"}]
        real_write = setup.private_write
        def fail_state(path, *args, **kwargs):
            if Path(path) == self.state: raise OSError("simulated disk error")
            return real_write(path, *args, **kwargs)
        with patch.object(setup, "private_write", side_effect=fail_state):
            with self.assertRaisesRegex(ValueError, "newly created key was removed"): self.run_complete()
        self.assertEqual(self.admin.keys, [{"AccessKeyId": "PREEXISTING_KEY", "Status": "Active"}])


if __name__ == "__main__": unittest.main()
