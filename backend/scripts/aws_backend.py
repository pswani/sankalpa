#!/usr/bin/env python3
"""Owned local/AWS lifecycle. Configuration is data; secrets never enter release manifests."""
from __future__ import annotations
import argparse
import base64
import calendar
import contextlib
import datetime as dt
import json
import os
from pathlib import Path
import re
import secrets
import sqlite3
import subprocess
import sys
import time
import urllib.error
import urllib.request
import uuid
from zoneinfo import ZoneInfo

ROOT = Path(__file__).resolve().parents[2]
BACKEND = ROOT / "backend"
PARTITION = "PRACTICE#default"
RUNTIME = {
    "SANKALPA_TIMEZONE": "PracticeTimezone", "SANKALPA_API_TOKEN": "ApiToken",
    "SANKALPA_ASSISTANT_ENABLED": "AssistantEnabled", "SANKALPA_LLM_PROVIDER": "LlmProvider",
    "SANKALPA_LLM_API_KEY": "LlmApiKey", "SANKALPA_LLM_MODEL": "LlmModel",
    "SANKALPA_LLM_REASONING_EFFORT": "LlmReasoningEffort", "SANKALPA_LLM_TIMEOUT": "LlmTimeout",
    "SANKALPA_ASSISTANT_RUNS_PER_MINUTE": "RunsPerMinute", "SANKALPA_ASSISTANT_RUNS_PER_DAY": "RunsPerDay",
}
DEFAULTS = {"DEPLOY_RESOURCE_PREFIX":"sankalpa", "DEPLOY_REGION":"us-east-1", "DEPLOY_MEMORY":"1024", "DEPLOY_TIMEOUT":"90",
    "DEPLOY_CONCURRENCY":"2", "DEPLOY_ARCHITECTURE":"arm64", "LOCAL_API_PORT":"8080", "LOCAL_DB_PORT":"8000",
    "SANKALPA_TIMEZONE":"America/Chicago", "SANKALPA_ASSISTANT_ENABLED":"false", "SANKALPA_LLM_PROVIDER":"fake",
    "SANKALPA_LLM_API_KEY":"", "SANKALPA_LLM_MODEL":"gpt-6-luna", "SANKALPA_LLM_REASONING_EFFORT":"none",
    "SANKALPA_LLM_TIMEOUT":"PT20S", "SANKALPA_ASSISTANT_RUNS_PER_MINUTE":"2", "SANKALPA_ASSISTANT_RUNS_PER_DAY":"20"}

def env_file(path):
    result = {}
    for number, raw in enumerate(Path(path).read_text().splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"): continue
        if "=" not in line: raise ValueError(f"Invalid environment assignment at line {number}")
        key, value = line.split("=",1); key=key.strip(); value=value.strip()
        if not re.fullmatch(r"[A-Z][A-Z0-9_]*",key) or key in result: raise ValueError(f"Invalid/duplicate environment key at line {number}")
        if value.startswith(("'", '"')):
            if value[-1:] != value[:1]: raise ValueError(f"Unclosed configuration quote at line {number}")
            value=value[1:-1]
        result[key]=value  # No interpolation, eval, source, command expansion, or shell parsing.
    return result

def configuration(args):
    cfg=dict(DEFAULTS)
    path=Path(args.env_file) if args.env_file else BACKEND / (".env.local" if args.target=="local" else f".env.{args.environment or 'prod'}")
    allowed=set(DEFAULTS)|set(RUNTIME)|{"DEPLOY_ACCOUNT_ID","DEPLOY_AWS_PROFILE","DEPLOY_ENVIRONMENT","DEPLOY_BUDGET_EMAIL","DEPLOY_RESTORED_TABLE_NAME","LOCAL_BIND_HOST","SANKALPA_DYNAMODB_TABLE","SANKALPA_IMAGE"}
    if path.exists():
        loaded=env_file(path)
        if set(loaded)-allowed: raise ValueError("Environment file contains unsupported configuration keys")
        cfg.update(loaded)
    elif args.env_file: raise ValueError("Selected environment file does not exist")
    # Only supported keys are consumed; process credentials remain in boto3's standard provider chain.
    cfg.update({k:v for k,v in os.environ.items() if k in allowed})
    for assignment in args.set:
        if "=" not in assignment: raise ValueError("--set requires KEY=VALUE")
        k,v=assignment.split("=",1)
        if k not in DEFAULTS and k not in RUNTIME and k not in {"DEPLOY_ACCOUNT_ID","DEPLOY_AWS_PROFILE","DEPLOY_ENVIRONMENT","LOCAL_BIND_HOST","SANKALPA_DYNAMODB_TABLE","DEPLOY_RESTORED_TABLE_NAME"}: raise ValueError("Unsupported configuration override")
        if any(word in k for word in ("TOKEN","KEY")): raise ValueError("Supply secret values through the environment file, not command arguments")
        cfg[k]=v
    cfg["DEPLOY_ENVIRONMENT"]=args.environment or cfg.get("DEPLOY_ENVIRONMENT", "dev" if args.target=="local" else "prod")
    if args.region: cfg["DEPLOY_REGION"]=args.region
    if args.profile: cfg["DEPLOY_AWS_PROFILE"]=args.profile
    if cfg["DEPLOY_ENVIRONMENT"] not in ({"dev","test"} if args.target=="local" else {"prod","staging"}): raise ValueError("Invalid target/environment combination")
    for key,low,high in [("DEPLOY_MEMORY",512,3072),("DEPLOY_TIMEOUT",45,120),("DEPLOY_CONCURRENCY",1,10),("LOCAL_API_PORT",1,65535),("LOCAL_DB_PORT",1,65535)]:
        if not low <= int(cfg[key]) <= high: raise ValueError(f"{key} outside supported range")
    if cfg["DEPLOY_ARCHITECTURE"] not in {"arm64","x86_64"}: raise ValueError("Unsupported architecture")
    ZoneInfo(cfg["SANKALPA_TIMEZONE"])
    if cfg["SANKALPA_ASSISTANT_ENABLED"] not in {"true","false"}: raise ValueError("Assistant enabled must be true or false")
    if not re.fullmatch(r"sankalpa(-[a-z][a-z0-9-]{0,20})?",cfg["DEPLOY_RESOURCE_PREFIX"]): raise ValueError("Resource prefix must remain in the owned Sankalpa namespace")
    cfg["SANKALPA_DYNAMODB_TABLE"]=(cfg.get("SANKALPA_DYNAMODB_TABLE","sankalpa-local") if args.target=="local" else cfg["DEPLOY_RESOURCE_PREFIX"]+"-"+cfg["DEPLOY_ENVIRONMENT"])
    cfg["_TARGET"]=args.target
    if not re.fullmatch(r"[a-z]{2}(?:-[a-z0-9]+)+-[0-9]+",cfg["DEPLOY_REGION"]): raise ValueError("Invalid AWS Region")
    return cfg

def require_token(cfg):
    token=cfg.get("SANKALPA_API_TOKEN","")
    if len(token)<32 or token.startswith("REPLACE_"): raise ValueError("Set a random SANKALPA_API_TOKEN of at least 32 characters in the ignored environment file")
    if cfg["SANKALPA_ASSISTANT_ENABLED"]=="true" and cfg["SANKALPA_LLM_PROVIDER"]=="openai" and not cfg["SANKALPA_LLM_API_KEY"]: raise ValueError("Enabled OpenAI assistant requires its provider key")

def run(command, *, environment=None, capture=False, input=None):
    process=subprocess.run(command,cwd=BACKEND,env=environment,input=input,text=True,capture_output=capture)
    if process.returncode: raise RuntimeError(f"Command failed: {Path(command[0]).name}")
    return process.stdout if capture else None

def state_path(cfg):
    scope=cfg["DEPLOY_RESOURCE_PREFIX"]+"-"+cfg["DEPLOY_ENVIRONMENT"]+"-"+cfg.get("_TARGET","local")
    if cfg.get("_TARGET")=="aws": scope+="-"+cfg["DEPLOY_ACCOUNT_ID"]+"-"+cfg["DEPLOY_REGION"]
    path=BACKEND/".aws-state"/(scope+".json"); path.parent.mkdir(parents=True,exist_ok=True)
    return path

def read_state(cfg):
    path=state_path(cfg); return json.loads(path.read_text()) if path.exists() else {}

def write_state(cfg,state):
    path=state_path(cfg); tmp=path.with_suffix(".tmp"); tmp.write_text(json.dumps(state,indent=2)); tmp.chmod(0o600); tmp.replace(path)

def boto_session(cfg, local=False):
    import boto3
    if local: return boto3.Session(region_name=cfg["DEPLOY_REGION"],aws_access_key_id="local",aws_secret_access_key="local")
    return boto3.Session(region_name=cfg["DEPLOY_REGION"],profile_name=cfg.get("DEPLOY_AWS_PROFILE") or None)

def database(cfg,target, endpoint=None):
    session=boto_session(cfg,target=="local")
    return session.client("dynamodb",endpoint_url=endpoint or (f"http://127.0.0.1:{cfg['LOCAL_DB_PORT']}" if target=="local" else None))

def item_key(key): return {"PK":{"S":PARTITION},"SK":{"S":key}}
def encode_item(key,value):
    item=item_key(key); item["payload"]={"S":json.dumps(value,ensure_ascii=False,separators=(",",":"))}
    if "ttlEpoch" in value: item["ttlEpoch"]={"N":str(value["ttlEpoch"])}
    if len(item["payload"]["S"].encode())+len(key.encode())+128>400*1024: raise ValueError("Import record exceeds DynamoDB item limit")
    return item
def get_doc(client,table,key):
    item=client.get_item(TableName=table,Key=item_key(key),ConsistentRead=True).get("Item")
    return json.loads(item["payload"]["S"]) if item else None
def all_docs(client,table):
    result={}; cursor=None
    while True:
        kwargs=dict(TableName=table,ConsistentRead=True,KeyConditionExpression="PK = :pk",ExpressionAttributeValues={":pk":{"S":PARTITION}})
        if cursor: kwargs["ExclusiveStartKey"]=cursor
        page=client.query(**kwargs)
        for item in page["Items"]: result[item["SK"]["S"]]=json.loads(item["payload"]["S"])
        cursor=page.get("LastEvaluatedKey")
        if not cursor: return result

def ensure_local_table(client,table):
    if not table.startswith("sankalpa-"): raise ValueError("Local table must use Sankalpa namespace")
    try: client.describe_table(TableName=table)
    except client.exceptions.ResourceNotFoundException:
        client.create_table(TableName=table,BillingMode="PAY_PER_REQUEST",AttributeDefinitions=[{"AttributeName":k,"AttributeType":"S"} for k in ("PK","SK")],KeySchema=[{"AttributeName":"PK","KeyType":"HASH"},{"AttributeName":"SK","KeyType":"RANGE"}])
        client.get_waiter("table_exists").wait(TableName=table)

def init_db(client,table):
    records=all_docs(client,table)
    if records:
        if len(records)==1 and records.get("META",{}).get("status")=="READY": return
        raise ValueError("Initialization requires an empty target; use validate for an existing practice")
    meta={"schemaVersion":1,"status":"READY","serviceInstanceId":str(uuid.uuid4()),"practiceRevision":0,"commitSequence":0}
    client.put_item(TableName=table,Item=encode_item("META",meta),ConditionExpression="attribute_not_exists(PK)")

def timestamp(value):
    parsed=dt.datetime.fromisoformat(value)
    if parsed.tzinfo is not None: raise ValueError("Stored practice timestamps must be offset-free")
    fraction=value.partition(".")[2]
    if fraction and (not fraction.isdigit() or len(fraction)>9): raise ValueError("Invalid timestamp precision")
    return parsed.strftime("%Y-%m-%dT%H:%M:%S")+"."+fraction.ljust(9,"0")


def sqlite_documents(path):
    source=Path(path).resolve()
    if not source.is_file(): raise ValueError("SQLite source does not exist")
    # Read-only SQLite backup API gives a consistent snapshot without modifying the live file.
    with contextlib.closing(sqlite3.connect(source.as_uri()+"?mode=ro",uri=True)) as original, contextlib.closing(sqlite3.connect(":memory:")) as db:
        original.backup(db); db.row_factory=sqlite3.Row
        metadata=dict(db.execute("SELECT metadata_key,metadata_value FROM service_metadata"))
        if metadata.get("linked_extensions_schema")!="1" or not metadata.get("service_instance_id"): raise ValueError("Migrate/validate SQLite with the existing backend before importing")
        docs={"META":{"schemaVersion":1,"status":"IMPORTING","serviceInstanceId":metadata["service_instance_id"],"practiceRevision":int(metadata["practice_revision"]),"commitSequence":0}}
        vows={r["id"]:dict(r) for r in db.execute("SELECT * FROM sankalpa")}
        for id,row in vows.items():
            history=[]
            for t in db.execute("SELECT * FROM sankalpa_lifecycle_transition WHERE sankalpa_id=? ORDER BY sequence_number",(id,)):
                if t["sequence_number"]!=len(history): raise ValueError("Invalid SQLite audit sequence")
                history.append({"from":t["from_state"],"to":t["to_state"],"effectiveAt":t["effective_at"],"recordedAt":t["recorded_at"],"originSankalpaId":{"value":t["origin_sankalpa_id"]}})
            value={"id":id,"title":row["title"],"description":row["description"],"actionType":row["action_type"],"startDate":row["start_date"],"periodUnit":row["period_unit"],"timesPerPeriod":row["times_per_period"],"periodCount":row["period_count"],"declaredAt":row["declared_at"],"currentState":row["current_state"],"version":row["version"],"seriesId":row["series_id"],"extensionOf":row["extension_of"],"history":history}
            docs["VOW#"+id]=value
            docs[f"SERIES#{value['seriesId']}#{value['periodCount'] or 0:04d}#{id}"]={"id":id}
            if value["extensionOf"]:
                key="EXTENSION#"+value["extensionOf"]
                if key in docs: raise ValueError("Branching SQLite extension")
                docs[key]={"id":id}
        facts={r["id"]:dict(r) for r in db.execute("SELECT * FROM practice_session")}
        for row in db.execute("SELECT * FROM session_identity"):
            id=row["session_id"]; fact=facts.pop(id,None)
            if (row["identity_state"]=="ACTIVE") != bool(fact): raise ValueError("Inconsistent SQLite session identity")
            if fact and fact["sankalpa_id"]!=row["sankalpa_id"]: raise ValueError("Session owner mismatch")
            value={"id":id,"owner":row["sankalpa_id"],"state":row["identity_state"],"occurredAt":fact["occurred_at"] if fact else None,"loggedAt":fact["logged_at"] if fact else None}
            docs["SESSION#"+id]=value
            if fact:
                suffix=timestamp(value["occurredAt"])+"#"+id
                docs["JOURNAL#"+suffix]=value; docs["OWNER#"+value["owner"]+"#"+suffix]=value
        if facts: raise ValueError("Session facts missing identity ledger")
        for row in db.execute("SELECT * FROM assistant_proposal"):
            p={"id":row["proposal_id"],"threadId":row["thread_id"],"sourceRunId":row["source_run_id"],"kind":row["kind"],"schemaVersion":row["schema_version"],"payload":json.loads(row["payload_json"]),"status":row["status"],"confirmationId":row["confirmation_id"],"resultResourceId":row["result_resource_id"],"failureCode":row["failure_code"],"createdAt":row["created_at"],"expiresAt":row["expires_at"],"resolvedAt":row["resolved_at"]}
            docs["PROPOSAL#"+p["id"]]=p; docs["RUN#"+p["sourceRunId"]]={"id":p["id"]}
            if p["confirmationId"]: docs["CONFIRM#"+p["confirmationId"]]={"id":p["id"]}
            if p["status"]=="PENDING":
                key="THREAD#"+p["threadId"]
                if key in docs: raise ValueError("Multiple pending proposals in one thread")
                docs[key]={"id":p["id"]}
        validate_documents(docs,allow_importing=True)
        for key,value in docs.items(): encode_item(key,value)
        return docs

def validate_documents(docs,allow_importing=False):
    meta=docs.get("META",{})
    if meta.get("status") not in ({"READY","IMPORTING"} if allow_importing else {"READY"}) or meta.get("schemaVersion")!=1: raise ValueError("Database metadata is not READY/supported")
    uuid.UUID(meta["serviceInstanceId"])
    if min(meta["practiceRevision"],meta["commitSequence"])<0: raise ValueError("Invalid revision")
    vows={k[4:]:v for k,v in docs.items() if k.startswith("VOW#")}
    for id,v in vows.items():
        if v["id"]!=id or v["seriesId"] not in vows: raise ValueError("Invalid vow identity/root")
        source=v.get("extensionOf")
        if source:
            if source not in vows or vows[source]["seriesId"]!=v["seriesId"] or not vows[source]["periodCount"] or v["periodCount"]<=vows[source]["periodCount"]: raise ValueError("Invalid linked relationship")
            if docs.get("EXTENSION#"+source)!={"id":id}: raise ValueError("Missing extension claim")
        elif v["seriesId"]!=id: raise ValueError("Root vow has another series identity")
        if docs.get(f"SERIES#{v['seriesId']}#{v['periodCount'] or 0:04d}#{id}")!={"id":id}: raise ValueError("Missing series membership")
        state="NOT_STARTED"; previous=None
        legal={"NOT_STARTED":{"IN_PROGRESS","COMPLETED_SUCCESSFULLY","COMPLETED_UNSUCCESSFULLY","STOPPED"},"IN_PROGRESS":{"PAUSED","COMPLETED_SUCCESSFULLY","COMPLETED_UNSUCCESSFULLY","STOPPED"},"PAUSED":{"IN_PROGRESS","COMPLETED_SUCCESSFULLY","COMPLETED_UNSUCCESSFULLY","STOPPED"}}
        for t in v["history"]:
            if t["from"]!=state or t["to"] not in legal.get(state,set()) or t["originSankalpaId"]["value"] not in vows: raise ValueError("Invalid lifecycle audit")
            at=dt.datetime.fromisoformat(t["effectiveAt"]); recorded=dt.datetime.fromisoformat(t["recordedAt"])
            if at>recorded or (previous and (at<previous[0] or recorded<previous[1])): raise ValueError("Regressing audit times")
            previous=(at,recorded); state=t["to"]
        if state!=v["currentState"]: raise ValueError("Lifecycle state/audit mismatch")
    expected=set()
    for key,s in docs.items():
        if not key.startswith("SESSION#"): continue
        if s["owner"] not in vows or key!="SESSION#"+s["id"] or s["state"] not in {"ACTIVE","DELETED"}: raise ValueError("Invalid session identity")
        if s["state"]=="ACTIVE":
            suffix=timestamp(s["occurredAt"])+"#"+s["id"]
            for projection in ("JOURNAL#"+suffix,"OWNER#"+s["owner"]+"#"+suffix):
                if docs.get(projection)!=s: raise ValueError("Session projection mismatch")
                expected.add(projection)
    actual={k for k in docs if k.startswith(("JOURNAL#","OWNER#"))}
    if expected!=actual: raise ValueError("Orphan session projection")
    for key,p in docs.items():
        if not key.startswith("PROPOSAL#"): continue
        if docs.get("RUN#"+p["sourceRunId"])!={"id":p["id"]}: raise ValueError("Missing proposal run identity")
        if p["confirmationId"] and docs.get("CONFIRM#"+p["confirmationId"])!={"id":p["id"]}: raise ValueError("Missing confirmation claim")
        if p["status"]=="PENDING" and docs.get("THREAD#"+p["threadId"])!={"id":p["id"]}: raise ValueError("Missing pending proposal")
    return {"vows":len(vows),"sessions":sum(k.startswith("SESSION#") for k in docs),"proposals":sum(k.startswith("PROPOSAL#") for k in docs)}

def import_db(client,table,path,verifier=None):
    docs=sqlite_documents(path)
    if all_docs(client,table): raise ValueError("Import requires an empty target; an interrupted import must be explicitly discarded in an offline environment")
    client.put_item(TableName=table,Item=encode_item("META",docs["META"]),ConditionExpression="attribute_not_exists(PK)")
    for key,value in docs.items():
        if key!="META": client.put_item(TableName=table,Item=encode_item(key,value),ConditionExpression="attribute_not_exists(PK)")
    loaded=all_docs(client,table)
    if loaded!=docs: raise ValueError("Import verification differs from source; target remains IMPORTING")
    validate_documents(loaded,allow_importing=True)
    if verifier: verifier()
    before=json.dumps(docs["META"],ensure_ascii=False,separators=(",",":")); docs["META"]["status"]="READY"
    client.put_item(TableName=table,Item=encode_item("META",docs["META"]),ConditionExpression="payload = :old",ExpressionAttributeValues={":old":{"S":before}})
    print("Imported and verified practice",json.dumps(validate_documents(docs)))

def verify_domain(cfg, table, target):
    jars=[p for p in (BACKEND/"target").glob("sankalpa-backend-*.jar") if not p.name.endswith(".original")]
    if not jars:
        run(["mvn","-Dmaven.repo.local=.m2/repository","--batch-mode","verify"])
        jars=list((BACKEND/"target").glob("sankalpa-backend-*.jar"))
    environment=dict(os.environ)
    if cfg.get("DEPLOY_AWS_PROFILE"): environment["AWS_PROFILE"]=cfg["DEPLOY_AWS_PROFILE"]
    endpoint=f"http://127.0.0.1:{cfg['LOCAL_DB_PORT']}" if target=="local" else "-"
    run(["java","-Dloader.main=com.sankalpa.adapter.out.dynamodb.DatabaseVerifier","-cp",str(jars[0]),"org.springframework.boot.loader.launch.PropertiesLauncher",table,cfg["DEPLOY_REGION"],endpoint],environment=environment)


def request(url,path,token=None,body=None,extra_headers=None,method=None):
    headers={"Content-Type":"application/json"}
    if extra_headers: headers.update(extra_headers)
    if token: headers["Authorization"]="Bearer "+token
    req=urllib.request.Request(url.rstrip("/")+path,data=None if body is None else json.dumps(body).encode(),headers=headers,method=method)
    try:
        with urllib.request.urlopen(req,timeout=110) as response: return response.status,response.headers,response.read()
    except urllib.error.HTTPError as response: return response.code,response.headers,response.read()

def smoke(url,cfg,mutations=False):
    require_token(cfg)
    for attempt in range(30):
        try:
            if request(url,"/health/ready")[0]==200: break
        except (urllib.error.URLError,TimeoutError,OSError): pass
        time.sleep(2)
    else: raise RuntimeError("Backend did not become ready")
    if request(url,"/api/v1/capabilities")[0]!=401: raise RuntimeError("Anonymous API access was not refused")
    status,_,body=request(url,"/api/v1/capabilities",cfg["SANKALPA_API_TOKEN"])
    if status!=200: raise RuntimeError("Authenticated capability check failed")
    capability=json.loads(body)
    if not capability.get("serviceInstanceId"): raise RuntimeError("Missing service identity")
    status,_,_=request(url,"/api/v1/sankalpas",cfg["SANKALPA_API_TOKEN"],extra_headers={"Linked-Sankalpa-Version":"1","Sankalpa-Service-Instance":capability["serviceInstanceId"]})
    if status!=200: raise RuntimeError("Database-backed practice read failed")
    if mutations:
        now=dt.datetime.now(ZoneInfo(cfg["SANKALPA_TIMEZONE"])); token=cfg["SANKALPA_API_TOKEN"]
        status,_,body=request(url,"/api/v1/sankalpas",token,{"title":"AWS verification "+uuid.uuid4().hex[:8],"description":"Disposable staging verification","actionType":"MEDITATION","startDate":(now.date()-dt.timedelta(days=1)).isoformat(),"periodUnit":"DAY","timesPerPeriod":1,"periodCount":40})
        if status!=201: raise RuntimeError("Staging declaration verification failed")
        owner=json.loads(body)["id"]; base="/api/v1/sankalpas/"+owner
        headers={"Linked-Sankalpa-Version":"1","Sankalpa-Service-Instance":capability["serviceInstanceId"]}
        if request(url,base+"/begin",token,{"effectiveAt":(now-dt.timedelta(minutes=1)).replace(tzinfo=None).isoformat()},headers)[0]!=200:
            raise RuntimeError("Staging lifecycle verification failed")
        session=str(uuid.uuid4()); session_headers={**headers,"Idempotency-Key":session}
        fact={"id":session,"occurredAt":(now-dt.timedelta(seconds=30)).replace(tzinfo=None).isoformat()}
        if request(url,base+"/sessions",token,fact,session_headers)[0]!=201 or request(url,base+"/sessions",token,fact,session_headers)[0]!=200:
            raise RuntimeError("Staging session replay verification failed")
        extension=str(uuid.uuid4()); extension_headers={**headers,"Idempotency-Key":extension}
        extended={"id":extension,"totalPeriodCount":90}
        if request(url,base+"/extensions",token,extended,extension_headers)[0]!=201 or request(url,base+"/extensions",token,extended,extension_headers)[0]!=200:
            raise RuntimeError("Staging extension replay verification failed")
        for vow in (owner,extension):
            status,_,body=request(url,"/api/v1/sankalpas/"+vow+"/sessions",token,extra_headers=headers)
            if status!=200 or len(json.loads(body)["content"])!=1: raise RuntimeError("Staging shared session read failed")
        for attempt in range(2):
            if request(url,base+"/sessions/"+session,token,extra_headers=headers,method="DELETE")[0]!=204: raise RuntimeError("Staging deletion replay failed")
        if request(url,base+"/sessions",token,fact,session_headers)[0]!=410: raise RuntimeError("Deleted session identity was resurrected")
        print("Staging lifecycle, linked-session, identity replay and tombstone verification passed")
    print("Readiness/authentication/database access verified; service identity:",capability["serviceInstanceId"])

class Cloud:
    def __init__(self,cfg):
        self.cfg=cfg; self.environment=cfg["DEPLOY_ENVIRONMENT"]; self.name=cfg["DEPLOY_RESOURCE_PREFIX"]+"-"+self.environment
        expected=cfg.get("DEPLOY_ACCOUNT_ID","")
        if not re.fullmatch(r"\d{12}",expected): raise ValueError("Configure DEPLOY_ACCOUNT_ID before AWS operations")
        self.session=boto_session(cfg); self.account=self.session.client("sts").get_caller_identity()["Account"]
        if self.account!=expected: raise ValueError("AWS credential account does not match configured account")
        self.cf=self.session.client("cloudformation"); self.lam=self.session.client("lambda"); self.ecr=self.session.client("ecr"); self.db=self.session.client("dynamodb")
    def stack(self,name):
        try: stack=self.cf.describe_stacks(StackName=name)["Stacks"][0]
        except self.cf.exceptions.ClientError as error:
            if error.response["Error"]["Code"]=="ValidationError" and "does not exist" in error.response["Error"]["Message"]: return None
            raise
        tags={t["Key"]:t["Value"] for t in stack.get("Tags",[])}
        if tags.get("Project")!="Sankalpa" or tags.get("Environment")!=self.environment: raise ValueError("Refusing unowned infrastructure stack")
        return stack
    def outputs(self,name):
        stack=self.stack(name)
        if not stack: raise ValueError("Required foundation/application stack is absent")
        return {o["OutputKey"]:o["OutputValue"] for o in stack.get("Outputs",[])}
    def apply(self,name,template,params):
        stack=self.stack(name)
        if stack and stack["StackStatus"] not in {"CREATE_COMPLETE","UPDATE_COMPLETE","UPDATE_ROLLBACK_COMPLETE"}: raise ValueError("Stack is not in an updateable state; inspect its events")
        supplied=[{"ParameterKey":k,"ParameterValue":str(v)} for k,v in params.items()]
        if stack:
            supplied.extend({"ParameterKey":p["ParameterKey"],"UsePreviousValue":True} for p in stack.get("Parameters",[]) if p["ParameterKey"] not in params)
        kwargs=dict(StackName=name,ChangeSetName="release-"+uuid.uuid4().hex,ChangeSetType="UPDATE" if stack else "CREATE",TemplateBody=template,
            Parameters=supplied,Capabilities=["CAPABILITY_NAMED_IAM"],
            Tags=[{"Key":"Project","Value":"Sankalpa"},{"Key":"Environment","Value":self.environment},{"Key":"ManagedBy","Value":"CloudFormation"}])
        change=self.cf.create_change_set(**kwargs)["Id"]
        for _ in range(240):
            result=self.cf.describe_change_set(ChangeSetName=change)
            if result["Status"]=="CREATE_COMPLETE": break
            if result["Status"]=="FAILED":
                self.cf.delete_change_set(ChangeSetName=change)
                if "didn't contain changes" in result.get("StatusReason","") or "No updates" in result.get("StatusReason",""): return
                raise RuntimeError("CloudFormation change set failed; inspect Console events")
            time.sleep(2)
        else: raise RuntimeError("Change-set creation timed out")
        self.cf.execute_change_set(ChangeSetName=change)
        for _ in range(900):
            state=self.cf.describe_stacks(StackName=name)["Stacks"][0]["StackStatus"]
            if state in {"CREATE_COMPLETE","UPDATE_COMPLETE"}: print("Stack ready:",name); return
            if state.endswith(("FAILED","ROLLBACK_COMPLETE")): raise RuntimeError("Stack deployment failed; inspect CloudFormation events")
            time.sleep(2)
        raise RuntimeError("Stack deployment timed out")
    def budget(self):
        email=self.cfg.get("DEPLOY_BUDGET_EMAIL","")
        if not email: return
        client=self.session.client("budgets",region_name="us-east-1")
        name="Sankalpa Monthly"
        try: client.describe_budget(AccountId=self.account,BudgetName=name); print("Existing budget retained"); return
        except client.exceptions.NotFoundException: pass
        client.create_budget(AccountId=self.account,Budget={"BudgetName":name,"BudgetLimit":{"Amount":"5","Unit":"USD"},"TimeUnit":"MONTHLY","BudgetType":"COST"},
            NotificationsWithSubscribers=[{"Notification":{"NotificationType":"ACTUAL","ComparisonOperator":"GREATER_THAN","Threshold":n,"ThresholdType":"PERCENTAGE"},"Subscribers":[{"SubscriptionType":"EMAIL","Address":email}]} for n in (80,100)])
        print("Account-wide $5 budget configured")
    def check_concurrency(self):
        available=self.lam.get_account_settings()["AccountLimit"].get("UnreservedConcurrentExecutions",0)
        try: current=self.lam.get_function_concurrency(FunctionName=self.name).get("ReservedConcurrentExecutions",0)
        except self.lam.exceptions.ResourceNotFoundException: current=0
        if available-100+current<int(self.cfg["DEPLOY_CONCURRENCY"]):
            raise ValueError("Account concurrency quota cannot reserve this deployment; request a quota increase in Service Quotas")
    def setup(self):
        self.check_concurrency()
        restored=self.cfg.get("DEPLOY_RESTORED_TABLE_NAME","")
        if restored and not restored.startswith(self.name+"-restore-"): raise ValueError("Restored table must belong to the selected environment")
        parameters={"Environment":self.environment,"ResourcePrefix":self.cfg["DEPLOY_RESOURCE_PREFIX"]}
        if restored:
            validate_documents(all_docs(self.db,restored)); parameters["RestoredTableName"]=restored
        self.apply(self.name+"-foundation",(ROOT/"infra/foundation.yaml").read_text(),parameters); self.budget()
        print("Foundation ready. Initialize an empty practice or import an offline SQLite backup before deploying.")
    def app_parameters(self,image,release,production="",previous=""):
        require_token(self.cfg); foundation=self.outputs(self.name+"-foundation")
        p={"Environment":self.environment,"ResourcePrefix":self.cfg["DEPLOY_RESOURCE_PREFIX"],"TableName":foundation["TableName"],"RuntimeRoleArn":foundation["RuntimeRoleArn"],"ImageUri":image,"ReleaseId":release,
            "ProductionVersion":production,"RollbackVersion":previous,"Architecture":self.cfg["DEPLOY_ARCHITECTURE"],"MemorySize":self.cfg["DEPLOY_MEMORY"],"TimeoutSeconds":self.cfg["DEPLOY_TIMEOUT"],"ReservedConcurrency":self.cfg["DEPLOY_CONCURRENCY"]}
        p.update({parameter:self.cfg.get(key,DEFAULTS.get(key,"")) for key,parameter in RUNTIME.items()})
        if sum(len(k)+len(v.encode()) for k,v in self.cfg.items() if k in RUNTIME)>3300: raise ValueError("Runtime configuration exceeds environment budget")
        return p
    def versions(self):
        return [v for page in self.lam.get_paginator("list_versions_by_function").paginate(FunctionName=self.name) for v in page["Versions"]]
    def deploy(self,image=None,source_image=None):
        require_token(self.cfg)
        table=self.outputs(self.name+"-foundation")["TableName"]
        meta=get_doc(self.db,table,"META")
        if not meta or meta.get("status")!="READY": raise ValueError("Initialize/import and validate the practice before deployment")
        validate_documents(all_docs(self.db,table))
        old=self.stack(self.name+"-app")
        old_parameters={p["ParameterKey"]:p.get("ParameterValue","") for p in old.get("Parameters",[])} if old else {}
        previous=""; production=""
        if old:
            production=self.lam.get_alias(FunctionName=self.name,Name="prod")["FunctionVersion"]
            previous=self.lam.get_alias(FunctionName=self.name,Name="rollback")["FunctionVersion"]
            if self.lam.get_function_concurrency(FunctionName=self.name).get("ReservedConcurrentExecutions")==0: raise ValueError("Deployment is stopped; run start explicitly before deploying")
        release="release-"+dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")+"-"+uuid.uuid4().hex[:8]
        if not image:
            image=self.push(release,source_image)
        repository=self.outputs(self.name+"-foundation")["RepositoryUri"]
        if not image.startswith(repository+"@sha256:"): raise ValueError("Deploy only a digest from the selected owned repository")
        p=self.app_parameters(image,release,production,previous)
        template=(ROOT/"infra/application.yaml").read_text()
        self.apply(self.name+"-app",template,p)
        out=self.outputs(self.name+"-app")
        smoke(out["CandidateUrl"],self.cfg,False)
        version=out["CandidateVersion"]
        if production:
            p["RollbackVersion"]=production; p["ProductionVersion"]=version
            self.apply(self.name+"-app",template,p)
        print("Production endpoint:",out["ProductionUrl"])
        write_state(self.cfg,{"account":self.account,"region":self.cfg["DEPLOY_REGION"],"productionVersion":version,"previousVersion":production or version,"image":image})
    def push(self,release,source_image=None):
        uri=self.outputs(self.name+"-foundation")["RepositoryUri"]; image=uri+":"+release
        if source_image:
            verify_image(source_image,self.cfg)
            run(["docker","tag",source_image,image])
        else: build_image(self.cfg,image)
        authorization=self.ecr.get_authorization_token()["authorizationData"][0]
        user,password=base64.b64decode(authorization["authorizationToken"]).decode().split(":",1)
        run(["docker","login","--username",user,"--password-stdin",authorization["proxyEndpoint"]],input=password,capture=True)
        run(["docker","push",image])
        digest=self.ecr.describe_images(repositoryName=self.name,imageIds=[{"imageTag":release}])["imageDetails"][0]["imageDigest"]
        return uri+"@"+digest
    def update_parameters(self,changes):
        stack=self.stack(self.name+"-app")
        if not stack: raise ValueError("Application stack is absent")
        current={p["ParameterKey"]:p.get("ParameterValue") for p in stack["Parameters"]}
        if all(current.get(k)==str(v) for k,v in changes.items()):
            if "ReservedConcurrency" in changes:
                requested=int(changes["ReservedConcurrency"])
                if self.lam.get_function_concurrency(FunctionName=self.name).get("ReservedConcurrentExecutions")!=requested:
                    self.lam.put_function_concurrency(FunctionName=self.name,ReservedConcurrentExecutions=requested)
            print("Configuration already selected or reconciled"); return
        template=self.cf.get_template(StackName=self.name+"-app")["TemplateBody"]
        if not isinstance(template,str): template=json.dumps(template)
        # Preserve NoEcho parameters using UsePreviousValue, never the masked response value.
        change=self.cf.create_change_set(StackName=self.name+"-app",ChangeSetName="operation-"+uuid.uuid4().hex,ChangeSetType="UPDATE",TemplateBody=template,
            Parameters=[{"ParameterKey":p["ParameterKey"],**({"ParameterValue":str(changes[p["ParameterKey"]])} if p["ParameterKey"] in changes else {"UsePreviousValue":True})} for p in stack["Parameters"]],Capabilities=["CAPABILITY_NAMED_IAM"])["Id"]
        self.cf.get_waiter("change_set_create_complete").wait(ChangeSetName=change)
        self.cf.execute_change_set(ChangeSetName=change); self.cf.get_waiter("stack_update_complete").wait(StackName=self.name+"-app")
    def rollback(self):
        version=self.lam.get_alias(FunctionName=self.name,Name="rollback")["FunctionVersion"]
        image=self.lam.get_function(FunctionName=self.name,Qualifier=version)["Code"]["ResolvedImageUri"]
        # Re-publish old code with current env-file credentials; do not revive a revoked token.
        self.deploy(image)
    def cleanup(self):
        self.stack(self.name+"-app"); self.stack(self.name+"-foundation"); self.check_repository()
        keep={a["FunctionVersion"] for page in self.lam.get_paginator("list_aliases").paginate(FunctionName=self.name) for a in page["Aliases"]}
        resources=[r for page in self.cf.get_paginator("list_stack_resources").paginate(StackName=self.name+"-app") for r in page["StackResourceSummaries"]]
        for resource in resources:
            if resource["ResourceType"]=="AWS::Lambda::Version": keep.add(resource["PhysicalResourceId"].rsplit(":",1)[-1])
        digests=set()
        for version in self.versions():
            number=version["Version"]
            if number!="$LATEST" and number not in keep:
                self.lam.delete_function(FunctionName=self.name,Qualifier=number); print("Removed unused version",number)
            else:
                uri=self.lam.get_function(FunctionName=self.name,Qualifier=number)["Code"].get("ResolvedImageUri","")
                if "@" in uri: digests.add(uri.split("@",1)[1])
        # Another Lambda can share an image. Never infer image safety only from this function.
        try:
            for page in self.lam.get_paginator("list_functions").paginate():
                for function in page["Functions"]:
                    if function["FunctionName"]==self.name or function.get("PackageType")!="Image": continue
                    for versions in self.lam.get_paginator("list_versions_by_function").paginate(FunctionName=function["FunctionName"]):
                        for version in versions["Versions"]:
                            uri=self.lam.get_function(FunctionName=function["FunctionName"],Qualifier=version["Version"])["Code"].get("ResolvedImageUri","")
                            if "@" in uri: digests.add(uri.split("@",1)[1])
        except Exception:
            print("Retained images because references from another image function could not be established"); return
        for page in self.ecr.get_paginator("describe_images").paginate(repositoryName=self.name):
            for image in page["imageDetails"]:
                if image["imageDigest"] not in digests: self.ecr.batch_delete_image(repositoryName=self.name,imageIds=[{"imageDigest":image["imageDigest"]}])
        print("Cleanup retained all aliases, managed versions and practice data")
    def assert_resource_tags(self, tags):
        values={t["Key"]:t["Value"] for t in tags}
        if values.get("Project")!="Sankalpa" or values.get("Environment")!=self.environment:
            raise ValueError("Refusing to delete resource without matching ownership tags")
    def check_repository(self):
        repository=self.ecr.describe_repositories(repositoryNames=[self.name])["repositories"][0]
        self.assert_resource_tags(self.ecr.list_tags_for_resource(resourceArn=repository["repositoryArn"])["tags"])
    def destroy_staging(self):
        if self.environment!="staging": raise ValueError("Destructive teardown is available only for staging")
        self.check_repository()
        table=self.db.describe_table(TableName=self.name)["Table"]["TableArn"]
        self.assert_resource_tags(self.db.list_tags_of_resource(ResourceArn=table)["Tags"])
        log_arn=f"arn:aws:logs:{self.cfg['DEPLOY_REGION']}:{self.account}:log-group:/aws/lambda/{self.name}"
        logs=self.session.client("logs")
        self.assert_resource_tags([{"Key":k,"Value":v} for k,v in logs.list_tags_for_resource(resourceArn=log_arn)["tags"].items()])
        for suffix in ("-app","-foundation"):
            if self.stack(self.name+suffix): self.cf.delete_stack(StackName=self.name+suffix); self.cf.get_waiter("stack_delete_complete").wait(StackName=self.name+suffix)
        self.db.update_table(TableName=self.name,DeletionProtectionEnabled=False)
        self.db.get_waiter("table_exists").wait(TableName=self.name)
        self.db.delete_table(TableName=self.name)
        self.db.get_waiter("table_not_exists").wait(TableName=self.name)
        self.ecr.delete_repository(repositoryName=self.name,force=True)
        self.session.client("logs").delete_log_group(logGroupName="/aws/lambda/"+self.name)
        print("Removed disposable staging resources")

def build_image(cfg,image=None):
    run([sys.executable,"-m","unittest","discover","-s","scripts/tests"])
    run([str(BACKEND/".venv/bin/cfn-lint"),str(ROOT/"infra/foundation.yaml"),str(ROOT/"infra/application.yaml")])
    run(["mvn","-Dmaven.repo.local=.m2/repository","--batch-mode","verify"])
    image=image or "sankalpa-backend:release-"+uuid.uuid4().hex[:12]
    platform="linux/arm64" if cfg["DEPLOY_ARCHITECTURE"]=="arm64" else "linux/amd64"
    run(["docker","buildx","build","--platform",platform,"--provenance=false","--label","com.sankalpa.managed=true","--label","com.sankalpa.environment="+cfg["DEPLOY_ENVIRONMENT"],"--label","com.sankalpa.namespace="+cfg["DEPLOY_RESOURCE_PREFIX"]+"-"+cfg["DEPLOY_ENVIRONMENT"],"--load","-t",image,"."])
    return image

def verify_image(image,cfg):
    architecture=run(["docker","image","inspect","--format","{{.Os}}/{{.Architecture}}",image],capture=True).strip()
    expected="linux/arm64" if cfg["DEPLOY_ARCHITECTURE"]=="arm64" else "linux/amd64"
    if architecture!=expected: raise ValueError("Selected image does not match deployment platform")
    labels=json.loads(run(["docker","image","inspect","--format","{{json .Config.Labels}}",image],capture=True) or "{}") or {}
    if labels.get("com.sankalpa.managed")!="true": raise ValueError("Use an image produced by the verified backend build command")


def cleanup_local_images(cfg):
    protected=set()
    for path in (BACKEND/".aws-state").glob("*.json"):
        state=json.loads(path.read_text());protected.update(v for k,v in state.items() if k in {"image","previousImage"} and v)
    protected.update(run(["docker","ps","-a","--format","{{.Image}}"],capture=True).splitlines())
    for reference in run(["docker","image","ls","--filter","label=com.sankalpa.managed=true","--filter","label=com.sankalpa.environment="+cfg["DEPLOY_ENVIRONMENT"],"--filter","label=com.sankalpa.namespace="+cfg["DEPLOY_RESOURCE_PREFIX"]+"-"+cfg["DEPLOY_ENVIRONMENT"],"--format","{{.Repository}}:{{.Tag}}"],capture=True).splitlines():
        if reference not in protected and reference.startswith("sankalpa-backend:release-") and "<none>" not in reference:
            run(["docker","image","rm",reference])  # No force: Docker also protects referenced containers.


def compose(cfg,command,image=None,capture=False):
    environment={**os.environ,**cfg}
    if image: environment["SANKALPA_IMAGE"]=image
    return run(["docker","compose","--project-name",cfg["DEPLOY_RESOURCE_PREFIX"]+"-"+cfg["DEPLOY_ENVIRONMENT"],"-f",str(BACKEND/"compose.yaml"),*command],environment=environment,capture=capture)

def stop_owned_java(cfg):
    pid_file=BACKEND/"run/server.pid"
    if not pid_file.exists(): return
    value=pid_file.read_text().strip()
    if not value.isdigit(): raise ValueError("Invalid managed local PID record")
    pid=int(value)
    command=subprocess.run(["ps","-p",str(pid),"-o","command="],text=True,capture_output=True).stdout
    if not command.strip(): return
    if str(BACKEND/"target/sankalpa-backend-") not in command:
        raise ValueError("Refusing to stop PID belonging to another process")
    bound=subprocess.run(["lsof","-a","-p",str(pid),"-iTCP:"+cfg["LOCAL_API_PORT"],"-sTCP:LISTEN","-t"],text=True,capture_output=True).stdout
    if str(pid) not in bound.split(): return
    import signal
    os.kill(pid,signal.SIGTERM)
    for _ in range(40):
        try: os.kill(pid,0)
        except ProcessLookupError: pid_file.unlink(missing_ok=True);return
        time.sleep(0.25)
    raise RuntimeError("Previous managed backend did not stop; data retained, replacement aborted")


def local(args,cfg):
    command=args.command; state=read_state(cfg)
    url=f"http://127.0.0.1:{cfg['LOCAL_API_PORT']}"
    if command=="deploy":
        require_token(cfg); image=args.image or build_image(cfg)
        if args.image: verify_image(image,cfg)
        compose(cfg,["up","-d","dynamodb"],image)
        db=database(cfg,"local")
        for _ in range(30):
            try: ensure_local_table(db,cfg["SANKALPA_DYNAMODB_TABLE"]); break
            except Exception: time.sleep(1)
        else: raise RuntimeError("Local DynamoDB did not become ready")
        if not get_doc(db,cfg["SANKALPA_DYNAMODB_TABLE"],"META"): init_db(db,cfg["SANKALPA_DYNAMODB_TABLE"])
        stop_owned_java(cfg)
        compose(cfg,["up","-d","backend"],image)
        try: smoke(url,cfg)
        except Exception:
            if state.get("image"): compose(cfg,["up","-d","backend"],state["image"])
            raise
        write_state(cfg,{"image":image,"previousImage":state.get("image",image)})
    elif command=="rollback":
        if not state.get("previousImage"): raise ValueError("No previous local release")
        compose(cfg,["up","-d","backend"],state["previousImage"]); smoke(url,cfg)
        write_state(cfg,{"image":state["previousImage"],"previousImage":state.get("image")})
    elif command=="start": compose(cfg,["up","-d"],state.get("image")); smoke(url,cfg)
    elif command=="stop": compose(cfg,["stop"],state.get("image"))
    elif command=="status": compose(cfg,["ps"],state.get("image"))
    elif command=="logs": compose(cfg,["logs","--tail","100","backend"],state.get("image"))
    elif command=="cleanup":
        compose(cfg,["down","--remove-orphans"],state.get("image")); cleanup_local_images(cfg)  # Preserve volume/current/previous images.
    elif command=="test":
        run(["mvn","-Dmaven.repo.local=.m2/repository","--batch-mode","verify"])
        run([sys.executable,"-m","unittest","discover","-s","scripts/tests"])
        smoke(url,cfg,args.mutations)
    else: raise ValueError("Operation is not available for local target")

def main(argv=None):
    argv=list(sys.argv[1:] if argv is None else argv)
    if len(argv)>=2 and argv[0]=="db": argv[:2]=["db-"+argv[1]]
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command",choices=["setup","build","deploy","test","status","logs","stop","start","rollback","cleanup","destroy","db-init","db-import","db-validate"])
    parser.add_argument("--target",choices=["local","aws"],default="local")
    parser.add_argument("--environment"); parser.add_argument("--env-file"); parser.add_argument("--region"); parser.add_argument("--profile")
    parser.add_argument("--set",action="append",default=[]); parser.add_argument("--plan",action="store_true",help="Print nonsecret plan without contacting AWS or Docker")
    parser.add_argument("--image",help="Reuse a previously verified local image without rebuilding")
    parser.add_argument("--sqlite",help="Read-only SQLite source for import"); parser.add_argument("--mutations",action="store_true"); parser.add_argument("--yes",action="store_true")
    args=parser.parse_args(argv); cfg=configuration(args)
    if args.target=="aws" and cfg["DEPLOY_ENVIRONMENT"]=="prod" and args.mutations: raise ValueError("Mutation verification is forbidden in production")
    if args.plan:
        print(json.dumps({"operation":args.command,"target":args.target,"environment":cfg["DEPLOY_ENVIRONMENT"],"region":cfg["DEPLOY_REGION"],"table":cfg["SANKALPA_DYNAMODB_TABLE"],"secrets":"supplied separately; omitted"},indent=2)); return
    if args.command=="build": print("Built",build_image(cfg)); return
    cloud=Cloud(cfg) if args.target=="aws" else None
    if args.command.startswith("db-"):
        db=cloud.db if cloud else database(cfg,"local"); table=cloud.outputs(cloud.name+"-foundation")["TableName"] if cloud else cfg["SANKALPA_DYNAMODB_TABLE"]
        if not cloud: ensure_local_table(db,table)
        if args.command=="db-init": init_db(db,table); print("Empty practice initialized")
        elif args.command=="db-import":
            if not args.sqlite: raise ValueError("db import requires --sqlite")
            if cloud and cloud.stack(cloud.name+"-app"): raise ValueError("Import requires an offline target without an application stack")
            import_db(db,table,args.sqlite,lambda: verify_domain(cfg,table,args.target))
        else:
            print("Validated",json.dumps(validate_documents(all_docs(db,table)))); verify_domain(cfg,table,args.target)
        return
    if not cloud: local(args,cfg); return
    if args.command=="setup": cloud.setup()
    elif args.command=="deploy": cloud.deploy(source_image=args.image)
    elif args.command=="rollback": cloud.rollback()
    elif args.command in {"stop","start"}: cloud.update_parameters({"ReservedConcurrency":"0" if args.command=="stop" else cfg["DEPLOY_CONCURRENCY"]})
    elif args.command=="cleanup": cloud.cleanup()
    elif args.command=="destroy":
        if not args.yes: raise ValueError("Staging teardown requires --yes")
        cloud.destroy_staging()
    elif args.command=="test": smoke(cloud.outputs(cloud.name+"-app")["ProductionUrl"],cfg,args.mutations)
    elif args.command=="status":
        for suffix in ("-foundation","-app"):
            stack=cloud.stack(cloud.name+suffix); print(cloud.name+suffix,stack["StackStatus"] if stack else "absent")
        if cloud.stack(cloud.name+"-app"):
            print("Endpoint:",cloud.outputs(cloud.name+"-app")["ProductionUrl"])
            print("Serving version:",cloud.lam.get_alias(FunctionName=cloud.name,Name="prod")["FunctionVersion"])
            print("Rollback version:",cloud.lam.get_alias(FunctionName=cloud.name,Name="rollback")["FunctionVersion"])
    elif args.command=="logs":
        cloud.stack(cloud.name+"-app")
        events=cloud.session.client("logs").filter_log_events(logGroupName="/aws/lambda/"+cloud.name,limit=100)
        for event in events.get("events",[]): print(event["message"].rstrip())

if __name__=="__main__":
    try: main()
    except Exception as error:
        # AWS errors may contain request configuration; emit only their safe code.
        message=error.response.get("Error",{}).get("Code","AWS operation failed") if hasattr(error,"response") else str(error)
        print("Error:",message,file=sys.stderr); sys.exit(1)
