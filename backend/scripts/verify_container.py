#!/usr/bin/env python3
"""Disposable container lifecycle verification. No AWS credentials or user practice data."""
import argparse
import json
import secrets
import socket
import tempfile
import uuid
from pathlib import Path
import aws_backend as ops

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--skip-host-tests",action="store_true",help="Used after verify-aws-local.sh has already passed")
    parser.add_argument("--image",help="Test this verified local image without rebuilding or deleting it")
    parser.add_argument("--architecture",choices=["arm64","x86_64"],default="arm64")
    args=parser.parse_args()
    if not args.skip_host_tests:
        ops.run(["mvn","-Dmaven.repo.local=.m2/repository","--batch-mode","verify"])
        ops.run([str(ops.BACKEND/".venv/bin/python"),"-m","unittest","discover","-s","scripts/tests"])
        ops.run([str(ops.BACKEND/".venv/bin/cfn-lint"),str(ops.ROOT/"infra/foundation.yaml"),str(ops.ROOT/"infra/application.yaml")])
    suffix=uuid.uuid4().hex[:6]; prefix="sankalpa-verify-"+suffix; project=prefix+"-test"
    sockets=[socket.socket(),socket.socket()]
    for sock in sockets:sock.bind(("127.0.0.1",0))
    api_port,db_port=[s.getsockname()[1] for s in sockets]
    for sock in sockets:sock.close()
    owned_image="sankalpa-backend:release-verify-"+suffix
    image=args.image or owned_image
    image2=owned_image+"-second";bad=owned_image+"-bad";creator=project+"-creator"
    path=ops.BACKEND/".tools"/(project+".env");path.parent.mkdir(parents=True,exist_ok=True)
    cfg={**ops.DEFAULTS,"DEPLOY_ENVIRONMENT":"test","DEPLOY_RESOURCE_PREFIX":prefix,"_TARGET":"local",
         "DEPLOY_ARCHITECTURE":args.architecture,
         "LOCAL_API_PORT":str(api_port),"LOCAL_DB_PORT":str(db_port),"SANKALPA_DYNAMODB_TABLE":"sankalpa-test-"+suffix,
         "SANKALPA_API_TOKEN":secrets.token_urlsafe(32)}
    path.write_text("\n".join(f"{k}={v}" for k,v in cfg.items() if k!="_TARGET")+"\n");path.chmod(0o600)
    operation=argparse.Namespace(command="deploy",image=image,mutations=False)
    real_smoke=ops.smoke
    try:
        if args.image:
            ops.verify_image(image,cfg)
        else:
            ops.run(["docker","buildx","build","--platform","linux/arm64" if args.architecture=="arm64" else "linux/amd64","--provenance=false","--label","com.sankalpa.managed=true",
                     "--label","com.sankalpa.environment=test","--label","com.sankalpa.namespace="+project,"--load","-t",image,"."])
        ops.local(operation,cfg)
        url=f"http://127.0.0.1:{api_port}"
        real_smoke(url,cfg,True)
        identity=json.loads(ops.request(url,"/api/v1/capabilities",cfg["SANKALPA_API_TOKEN"])[2])["serviceInstanceId"]
        ops.run(["docker","tag",image,image2]);operation.image=image2;ops.local(operation,cfg)
        operation.command="rollback";ops.local(operation,cfg)
        assert ops.read_state(cfg)["image"]==image
        operation.command="stop";ops.local(operation,cfg)
        operation.command="start";ops.local(operation,cfg)
        assert json.loads(ops.request(url,"/api/v1/capabilities",cfg["SANKALPA_API_TOKEN"])[2])["serviceInstanceId"]==identity
        ops.run(["docker","create","--name",creator,"--entrypoint","/bin/sh",image,"-c","exit 1"],capture=True)
        ops.run(["docker","commit","--change",'ENTRYPOINT ["/bin/sh","-c","exit 1"]',creator,bad],capture=True)
        ops.run(["docker","rm",creator],capture=True)
        def failed_probe(url,cfg,*args,**kwargs):
            # The replacement really exits. Probe it directly before injecting a bounded failure.
            try:status=ops.request(url,"/health/ready")[0]
            except (OSError,ops.urllib.error.URLError):status=503
            if status==200:raise AssertionError("Exiting candidate was unexpectedly ready")
            raise RuntimeError("Expected failed candidate")
        ops.smoke=failed_probe;operation.command="deploy";operation.image=bad
        try:ops.local(operation,cfg)
        except RuntimeError:pass
        else:raise AssertionError("Failed candidate was promoted")
        finally:ops.smoke=real_smoke
        real_smoke(url,cfg)
        assert ops.read_state(cfg)["image"]==image
        db=ops.database(cfg,"local")
        assert ops.validate_documents(ops.all_docs(db,cfg["SANKALPA_DYNAMODB_TABLE"]))["vows"]==2
        ops.verify_domain(cfg,cfg["SANKALPA_DYNAMODB_TABLE"],"local")
        operation.command="cleanup";ops.local(operation,cfg)
        # Ordinary cleanup retained the practice volume; bringing it back preserves identity/data.
        operation.command="start";ops.local(operation,cfg)
        assert json.loads(ops.request(url,"/api/v1/capabilities",cfg["SANKALPA_API_TOKEN"])[2])["serviceInstanceId"]==identity
        print("PASS: container deployment, replacement, rollback, failure recovery, stop/start, cleanup and data retention")
    finally:
        ops.smoke=real_smoke
        try:ops.compose(cfg,["down","--volumes","--remove-orphans"],image)
        finally:
            for tag in ([image] if not args.image else [])+[image2,bad]:
                # No force; unrelated containers cannot be removed by image cleanup.
                try:ops.run(["docker","image","rm",tag],capture=True)
                except RuntimeError:pass
            path.unlink(missing_ok=True);ops.state_path(cfg).unlink(missing_ok=True)

if __name__=="__main__":main()
