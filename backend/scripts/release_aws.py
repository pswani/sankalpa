#!/usr/bin/env python3
"""Verify, build once, test the artifact, and publish a production-ready AWS release."""
from __future__ import annotations

import argparse
import contextlib
import datetime as dt
import fcntl
import hashlib
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import sys
import uuid

import aws_backend as ops

REQUIRED_CAPABILITIES = {"sessionCommandIdentity": 1, "linkedSankalpaExtensions": 1,
                         "assistantBatchSessions": 1, "assistantBeginCorrection": 1}
SOURCE_PATHS = ("backend/src", "backend/scripts", "backend/pom.xml", "backend/Dockerfile",
                "backend/.dockerignore", "infra", "app/Sankalpa", "app/SankalpaUITests",
                "app/SankalpaCore/Sources", "app/SankalpaCore/Tests",
                "app/SankalpaCore/Package.swift", "app/Sankalpa.xcodeproj/project.pbxproj",
                "app/Sankalpa.xcodeproj/xcshareddata", "app/scripts")


def source_fingerprint(root=ops.ROOT):
    digest = hashlib.sha256()
    files = []
    for name in SOURCE_PATHS:
        path = root / name
        files.extend(path.rglob("*") if path.is_dir() else [path])
    for path in sorted(set(files)):
        if not path.is_file() or any(p in {"__pycache__", "xcuserdata"} for p in path.parts):
            continue
        digest.update(path.relative_to(root).as_posix().encode() + b"\0" + path.read_bytes() + b"\0")
    return digest.hexdigest()


def test_environment():
    env = {k: v for k, v in os.environ.items()
           if not k.startswith(("SANKALPA_", "DEPLOY_", "AWS_"))}
    env.update(SANKALPA_ASSISTANT_ENABLED="false", SANKALPA_LLM_PROVIDER="fake",
               SANKALPA_API_TOKEN="", SANKALPA_LLM_API_KEY="",
               AWS_ACCESS_KEY_ID="local", AWS_SECRET_ACCESS_KEY="local",
               AWS_DEFAULT_REGION="us-east-1")
    return env


def check_capabilities(capability, identity=None):
    if identity and capability.get("serviceInstanceId") != identity:
        raise RuntimeError("Release changed the practice service identity")
    for key, value in REQUIRED_CAPABILITIES.items():
        if type(capability.get(key)) is not int or capability[key] != value:
            raise RuntimeError("Release is missing required capability: " + key)


def preflight(cfg):
    ops.require_token(cfg)
    cloud = ops.Cloud(cfg)
    cloud.check_concurrency()
    foundation = cloud.stack(cloud.name + "-foundation")
    if not foundation or foundation["StackStatus"] not in {"CREATE_COMPLETE", "UPDATE_COMPLETE", "UPDATE_ROLLBACK_COMPLETE"}:
        raise RuntimeError("Foundation stack is not ready; run setup before releasing")
    table = cloud.outputs(cloud.name + "-foundation")["TableName"]
    records = ops.all_docs(cloud.db, table)
    ops.validate_documents(records)
    if cfg["DEPLOY_ENVIRONMENT"] == "prod":
        description = cloud.db.describe_table(TableName=table)["Table"]
        recovery = cloud.db.describe_continuous_backups(TableName=table)["ContinuousBackupsDescription"]
        if not description.get("DeletionProtectionEnabled") or recovery["PointInTimeRecoveryDescription"]["PointInTimeRecoveryStatus"] != "ENABLED":
            raise RuntimeError("Production requires deletion protection and point-in-time recovery")
    app = cloud.stack(cloud.name + "-app")
    before = {"serviceInstanceId": records["META"]["serviceInstanceId"], "table": table}
    if app:
        if app["StackStatus"] not in {"CREATE_COMPLETE", "UPDATE_COMPLETE", "UPDATE_ROLLBACK_COMPLETE"}:
            raise RuntimeError("Application stack is not ready for a release")
        if cloud.lam.get_function_concurrency(FunctionName=cloud.name).get("ReservedConcurrentExecutions") == 0:
            raise RuntimeError("Deployment is stopped; run start explicitly before releasing")
        before["url"] = cloud.outputs(cloud.name + "-app")["ProductionUrl"]
        before["version"] = cloud.lam.get_alias(FunctionName=cloud.name, Name="prod")["FunctionVersion"]
    return cloud, before


class Release:
    def __init__(self, cfg, args):
        self.cfg, self.args = cfg, args
        self.id = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ") + "-" + uuid.uuid4().hex[:8]
        self.directory = ops.BACKEND / "logs/releases" / self.id
        self.directory.mkdir(parents=True, mode=0o700)
        self.report = {"release": self.id, "environment": cfg["DEPLOY_ENVIRONMENT"],
                       "region": cfg["DEPLOY_REGION"], "status": "running", "steps": []}
        self.save()

    def save(self):
        path = self.directory / "summary.json"
        temporary = path.with_suffix(".tmp")
        temporary.write_text(json.dumps(self.report, indent=2) + "\n")
        temporary.chmod(0o600)
        temporary.replace(path)

    def step(self, name, action):
        print("==>", name, flush=True)
        log = self.directory / (name + ".log")
        item = {"name": name, "status": "running", "log": str(log)}
        self.report["steps"].append(item)
        self.save()
        try:
            with log.open("w") as output:
                log.chmod(0o600)
                result = action(output)
        except BaseException:
            item["status"] = "failed"
            self.save()
            raise
        item["status"] = "passed"
        self.save()
        return result

    def command(self, name, command, cwd=ops.BACKEND, env=None):
        def execute(output):
            result = subprocess.run(command, cwd=cwd, env=env, stdout=output, stderr=subprocess.STDOUT)
            if result.returncode:
                raise RuntimeError("Stage failed: " + name + "; see " + str(output.name))
        return self.step(name, execute)

    def call(self, name, function):
        def execute(output):
            with contextlib.redirect_stdout(output), contextlib.redirect_stderr(output):
                return function()
        return self.step(name, execute)

    def image_id(self, image):
        return ops.run(["docker", "image", "inspect", "--format", "{{.Id}}", image], capture=True).strip()

    def verify_source(self, fingerprint):
        if source_fingerprint() != fingerprint or ops.configuration(self.args) != self.cfg:
            raise RuntimeError("Release inputs changed during verification; rerun the release")

    def run(self):
        cloud, before = (None, {}) if self.args.verify_only else self.call("aws-preflight", lambda: preflight(self.cfg))
        env = test_environment()
        fingerprint = source_fingerprint()
        self.report["sourceSha256"] = fingerprint
        self.report["before"] = before
        self.save()
        self.command("backend-tests", [str(ops.BACKEND / "scripts/verify-aws-local.sh")], env=env)
        self.command("reporting-tests", [sys.executable, "-m", "unittest", "discover", "-s", "app/scripts", "-p", "test_*.py"], cwd=ops.ROOT, env=env)
        if self.args.full_ios:
            # Unique test ports and simulator keep this run separate from development services.
            sockets = [socket.socket(), socket.socket()]
            try:
                for sock in sockets:
                    sock.bind(("127.0.0.1", 0))
                ports = [str(sock.getsockname()[1]) for sock in sockets]
            finally:
                for sock in sockets:
                    sock.close()
            ios_env = {**env, "TOUR_PORT": ports[0], "JOURNEY_PORT": ports[1],
                       "DEVICE_NAME": "Sankalpa-Release-" + self.id}
            try:
                self.command("ios-tests", [str(ops.ROOT / "app/scripts/test.sh")], cwd=ops.ROOT, env=ios_env)
            finally:
                self.remove_simulator(ios_env["DEVICE_NAME"])
        else:
            self.command("ios-package-tests", ["swift", "test", "--package-path", str(ops.ROOT / "app/SankalpaCore")], cwd=ops.ROOT, env=env)
        image = "sankalpa-backend:release-" + self.id
        platform = "linux/arm64" if self.cfg["DEPLOY_ARCHITECTURE"] == "arm64" else "linux/amd64"
        self.command("build-image", ["docker", "buildx", "build", "--platform", platform, "--provenance=false",
                     "--label", "com.sankalpa.managed=true", "--label", "com.sankalpa.environment=" + self.cfg["DEPLOY_ENVIRONMENT"],
                     "--label", "com.sankalpa.namespace=" + self.cfg["DEPLOY_RESOURCE_PREFIX"] + "-" + self.cfg["DEPLOY_ENVIRONMENT"],
                     "--load", "-t", image, "."], env=env)
        built_id = self.image_id(image)
        self.report.update(localImage=image, imageId=built_id)
        self.save()
        self.command("container-tests", [sys.executable, "scripts/verify_container.py", "--skip-host-tests", "--image", image,
                     "--architecture", self.cfg["DEPLOY_ARCHITECTURE"]], env=env)
        self.verify_source(fingerprint)
        if self.image_id(image) != built_id:
            raise RuntimeError("Verified image tag changed; refusing deployment")
        if self.args.verify_only:
            self.report["status"] = "verified"
            self.save()
            return
        table = before["table"]
        self.call("database-validation-before", lambda: ops.verify_domain(self.cfg, table, "aws"))
        self.verify_source(fingerprint)
        self.call("deploy", lambda: cloud.deploy(source_image=image, candidate_check=lambda cap: check_capabilities(cap, before["serviceInstanceId"])))
        url = cloud.outputs(cloud.name + "-app")["ProductionUrl"]
        self.report["url"] = url
        self.report["version"] = cloud.lam.get_alias(FunctionName=cloud.name, Name="prod")["FunctionVersion"]
        if before.get("url", url) != url:
            raise RuntimeError("Production URL changed; release is not verified")
        capability = self.call("production-smoke", lambda: ops.smoke(url, self.cfg))
        check_capabilities(capability, before["serviceInstanceId"])
        self.call("database-validation-after", lambda: ops.verify_domain(self.cfg, table, "aws"))
        self.report.update(status="deployed", serviceInstanceId=capability["serviceInstanceId"])
        self.save()

    def remove_simulator(self, name):
        listing = subprocess.run(["xcrun", "simctl", "list", "devices", "-j"], capture_output=True, text=True)
        if listing.returncode:
            return
        for devices in json.loads(listing.stdout)["devices"].values():
            for device in devices:
                if device["name"] == name:
                    subprocess.run(["xcrun", "simctl", "shutdown", device["udid"]], capture_output=True)
                    subprocess.run(["xcrun", "simctl", "delete", device["udid"]], check=True, capture_output=True)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--environment", choices=["prod", "staging"], default="prod")
    parser.add_argument("--env-file")
    parser.add_argument("--profile")
    parser.add_argument("--region")
    parser.add_argument("--full-ios", action="store_true", help="Also gate on connected-app simulator tests and Release build")
    parser.add_argument("--verify-only", action="store_true", help="Run all local gates without contacting AWS")
    parser.add_argument("--plan", action="store_true", help="Show nonsecret stages without AWS, Docker or test calls")
    args = parser.parse_args(argv)
    args.target, args.set = "aws", []
    selected_file = Path(args.env_file) if args.env_file else ops.BACKEND / (".env." + args.environment)
    if selected_file.exists():
        declared = ops.env_file(selected_file).get("DEPLOY_ENVIRONMENT")
        if declared and declared != args.environment:
            raise ValueError("Environment file does not match the selected deployment environment; use a matching --environment and --env-file")
    cfg = ops.configuration(args)
    if args.plan:
        print(json.dumps({"environment": cfg["DEPLOY_ENVIRONMENT"], "region": cfg["DEPLOY_REGION"],
                          "namespace": cfg["DEPLOY_RESOURCE_PREFIX"], "fullIos": args.full_ios,
                          "deploy": not args.verify_only, "gates": ["backend", "operator", "templates", "reporting", "connected-ios", "exact-container-image", "database", "candidate", "production"]}, indent=2))
        return
    for tool in ("java", "mvn", "docker", "swift") + (("xcodebuild", "xcrun") if args.full_ios else ()):
        if not shutil.which(tool):
            raise RuntimeError("Required tool not installed: " + tool)
    scope = cfg["DEPLOY_RESOURCE_PREFIX"] + "-" + cfg["DEPLOY_ENVIRONMENT"] + "-" + cfg.get("DEPLOY_ACCOUNT_ID", "offline") + "-" + cfg["DEPLOY_REGION"]
    lock_path = ops.BACKEND / ".aws-state" / ("release-" + scope + ".lock")
    lock_path.parent.mkdir(parents=True, exist_ok=True)
    with lock_path.open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise RuntimeError("Another release is already running for this environment") from None
        release = Release(cfg, args)
        print("Release report:", release.directory / "summary.json", flush=True)
        try:
            release.run()
        except BaseException:
            release.report["status"] = "failed"
            release.save()
            raise
        print("Release", release.report["status"], "successfully", flush=True)
        if "url" in release.report:
            print("Production endpoint:", release.report["url"], flush=True)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("Release interrupted; inspect its report before retrying", file=sys.stderr)
        sys.exit(130)
    except Exception as error:
        message = error.response.get("Error", {}).get("Code", "AWS operation failed") if hasattr(error, "response") else str(error)
        print("Error:", message, file=sys.stderr)
        sys.exit(1)
