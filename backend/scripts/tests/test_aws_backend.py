import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import sqlite3
import tempfile
import unittest
import uuid
from unittest.mock import patch, Mock

spec=importlib.util.spec_from_file_location("aws_backend",Path(__file__).resolve().parents[1]/"aws_backend.py")
ops=importlib.util.module_from_spec(spec); spec.loader.exec_module(ops)

class MemoryClient:
    def __init__(self): self.data={};self.fail_key=None
    def query(self,**kwargs): return {"Items":list(self.data.values())}
    def get_item(self,**kwargs):
        item=self.data.get(kwargs["Key"]["SK"]["S"]);return {"Item":item} if item else {}
    def put_item(self,**kwargs):
        key=kwargs["Item"]["SK"]["S"]
        if key==self.fail_key: raise RuntimeError("Injected interruption")
        condition=kwargs.get("ConditionExpression","")
        if condition=="attribute_not_exists(PK)" and key in self.data: raise RuntimeError("Conditional conflict")
        if condition=="payload = :old" and self.data[key]["payload"]!=kwargs["ExpressionAttributeValues"][":old"]: raise RuntimeError("Conditional conflict")
        self.data[key]=kwargs["Item"]

def source_file(path):
    db=sqlite3.connect(path)
    db.executescript((ops.BACKEND/"src/main/resources/schema.sql").read_text())
    for statement in ["ALTER TABLE sankalpa ADD COLUMN series_id VARCHAR(36)","ALTER TABLE sankalpa ADD COLUMN extension_of VARCHAR(36)","ALTER TABLE sankalpa_lifecycle_transition ADD COLUMN origin_sankalpa_id VARCHAR(36)"]: db.execute(statement)
    owner=str(uuid.uuid4()); session=str(uuid.uuid4());instance=str(uuid.uuid4())
    for key,value in [("linked_extensions_schema","1"),("practice_revision","7"),("service_instance_id",instance)]:db.execute("INSERT INTO service_metadata VALUES (?,?)",(key,value))
    db.execute("INSERT INTO sankalpa VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)",(owner,"坐禅","Sit","MEDITATION","2026-10-01","DAY",1,40,"IN_PROGRESS","2026-10-01T12:00:00.000000000",1,owner,None))
    db.execute("INSERT INTO sankalpa_lifecycle_transition VALUES (?,?,?,?,?,?,?)",(owner,0,"NOT_STARTED","IN_PROGRESS","2026-10-01T12:00:00.000000000","2026-10-01T12:00:00.000000000",owner))
    db.execute("INSERT INTO practice_session VALUES (?,?,?,?)",(session,owner,"2026-10-02T08:00:00.123456789","2026-10-02T09:00:00.987654321"))
    db.execute("INSERT INTO session_identity VALUES (?,?,?)",(session,owner,"ACTIVE"));db.commit();db.close()
    return owner,session,instance

class OperatorTests(unittest.TestCase):
    def test_env_values_are_data_not_executed(self):
        with tempfile.TemporaryDirectory() as temp:
            path=Path(temp)/".env";marker=Path(temp)/"unsafe"
            path.write_text(f"SANKALPA_API_TOKEN=$(touch {marker})\nX='literal $HOME'\n")
            values=ops.env_file(path)
            self.assertEqual(values["X"],"literal $HOME");self.assertFalse(marker.exists())
    def test_duplicate_assignment_is_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            path=Path(temp)/".env";path.write_text("X=one\nX=two\n")
            with self.assertRaises(ValueError):ops.env_file(path)
    def test_plan_does_not_contact_aws_or_print_secrets(self):
        with tempfile.TemporaryDirectory() as temp,patch.object(ops,"Cloud",side_effect=AssertionError("Unexpected AWS call")):
            path=Path(temp)/".env";path.write_text("SANKALPA_API_TOKEN=super-secret-value\n")
            output=io.StringIO()
            with contextlib.redirect_stdout(output):ops.main(["setup","--target","aws","--env-file",str(path),"--plan"])
            self.assertNotIn("super-secret-value",output.getvalue());self.assertEqual(json.loads(output.getvalue())["table"],"sankalpa-prod")
    def test_production_mutation_tests_fail_before_aws(self):
        with patch.object(ops,"Cloud",side_effect=AssertionError("Unexpected AWS call")):
            with self.assertRaises(ValueError):ops.main(["test","--target","aws","--environment","prod","--mutations"])
    def test_secrets_cannot_be_passed_as_overrides(self):
        with self.assertRaises(ValueError):ops.main(["setup","--target","aws","--plan","--set","SANKALPA_API_TOKEN=secret"])
    def test_timestamp_preserves_nanoseconds(self):
        self.assertEqual(ops.timestamp("2026-10-02T08:00:00.123456789"),"2026-10-02T08:00:00.123456789")
        self.assertEqual(ops.timestamp("2026-10-02T08:00"),"2026-10-02T08:00:00.000000000")
        with self.assertRaises(ValueError):ops.timestamp("2026-10-02T08:00:00Z")
    def test_readiness_retries_startup_connection_reset(self):
        cfg={**ops.DEFAULTS,"SANKALPA_API_TOKEN":"x"*40}
        capability=json.dumps({"serviceInstanceId":str(uuid.uuid4())}).encode()
        responses=[ConnectionResetError("Starting"),(200,{},b""),(401,{},b""),(200,{},capability),(200,{},b"[]")]
        with patch.object(ops,"request",side_effect=responses),patch.object(ops.time,"sleep"),contextlib.redirect_stdout(io.StringIO()):
            ops.smoke("http://127.0.0.1:8080",cfg)
    def test_https_probe_uses_trusted_ca_without_disabling_verification(self):
        with patch.object(ops.urllib.request,"urlopen") as opened:
            opened.return_value.__enter__.return_value.status=200
            ops.request("https://example.com","/health/ready")
            context=opened.call_args.kwargs["context"]
            self.assertTrue(context.check_hostname)
            self.assertEqual(context.verify_mode,ops.ssl.CERT_REQUIRED)
            self.assertGreater(context.cert_store_stats()["x509_ca"],0)
    def test_initialization_cannot_overwrite_practice(self):
        client=MemoryClient();ops.init_db(client,"test")
        identity=ops.get_doc(client,"test","META")["serviceInstanceId"]
        ops.init_db(client,"test");self.assertEqual(ops.get_doc(client,"test","META")["serviceInstanceId"],identity)
        client.data["VOW#x"]=ops.encode_item("VOW#x",{})
        with self.assertRaises(ValueError):ops.init_db(client,"test")
    def test_import_keeps_ids_unicode_nanoseconds_and_revision(self):
        with tempfile.TemporaryDirectory() as temp:
            path=Path(temp)/"source.db";owner,session,identity=source_file(path);client=MemoryClient()
            with contextlib.redirect_stdout(io.StringIO()):ops.import_db(client,"test",path)
            docs=ops.all_docs(client,"test")
            self.assertEqual(docs["META"]["status"],"READY");self.assertEqual(docs["META"]["serviceInstanceId"],identity)
            self.assertEqual(docs["META"]["practiceRevision"],7);self.assertEqual(docs["VOW#"+owner]["title"],"坐禅")
            self.assertIn("JOURNAL#2026-10-02T08:00:00.123456789#"+session,docs)
            self.assertEqual(ops.validate_documents(docs)["sessions"],1)
            with self.assertRaises(ValueError):ops.import_db(client,"test",path)
    def test_interrupted_import_cannot_serve(self):
        with tempfile.TemporaryDirectory() as temp:
            path=Path(temp)/"source.db";owner,session,_=source_file(path);client=MemoryClient();client.fail_key="SESSION#"+session
            with self.assertRaises(RuntimeError):ops.import_db(client,"test",path)
            self.assertEqual(ops.get_doc(client,"test","META")["status"],"IMPORTING")
            with self.assertRaises(ValueError):ops.validate_documents(ops.all_docs(client,"test"))
    def test_corrupt_projection_is_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            path=Path(temp)/"source.db";source_file(path);docs=ops.sqlite_documents(path)
            key=next(k for k in docs if k.startswith("JOURNAL#"));del docs[key]
            with self.assertRaises(ValueError):ops.validate_documents(docs,allow_importing=True)
    def test_sqlite_export_retains_confirmed_begin_correction_audit(self):
        with tempfile.TemporaryDirectory() as temp:
            path=Path(temp)/"source.db";owner,_,_=source_file(path)
            receipt={"id":str(uuid.uuid4()),"previousEffectiveAt":"2026-10-01T12:00:00",
                     "correctedEffectiveAt":"2026-10-01T00:01:00","recordedAt":"2026-10-03T12:00:00"}
            with contextlib.closing(sqlite3.connect(path)) as db:
                db.execute("ALTER TABLE sankalpa_lifecycle_transition ADD COLUMN begin_corrections_json TEXT NOT NULL DEFAULT '[]'")
                db.execute("UPDATE sankalpa SET action_type='OBSERVANCE'")
                db.execute("UPDATE sankalpa_lifecycle_transition SET effective_at=?,begin_corrections_json=?",
                           (receipt["correctedEffectiveAt"],json.dumps([receipt])))
                db.commit()
            docs=ops.sqlite_documents(path)
            self.assertEqual(docs["VOW#"+owner]["history"][0]["beginCorrections"],[receipt])
            self.assertEqual(ops.validate_documents(docs,allow_importing=True)["sessions"],1)
    def test_oversized_import_fails_before_writing(self):
        client=MemoryClient()
        with tempfile.TemporaryDirectory() as temp:
            path=Path(temp)/"source.db";owner,_,_=source_file(path)
            with contextlib.closing(sqlite3.connect(path)) as db:
                db.execute("UPDATE sankalpa SET description=?",("x"*410000,));db.commit()
            with self.assertRaises(ValueError):ops.import_db(client,"test",path)
            self.assertFalse(client.data)
    def test_failed_candidate_never_promotes_production(self):
        cloud=object.__new__(ops.Cloud);cloud.cfg={**ops.DEFAULTS,"SANKALPA_API_TOKEN":"x"*40,"DEPLOY_ENVIRONMENT":"prod"};cloud.name="sankalpa-prod";cloud.environment="prod"
        cloud.db=MemoryClient();ops.init_db(cloud.db,cloud.name)
        cloud.stack=lambda name:{"Parameters":[]} if name.endswith("-app") else {}
        class Lambda:
            def get_alias(self,**kwargs):return {"FunctionVersion":"3" if kwargs["Name"]=="prod" else "2"}
            def get_function_concurrency(self,**kwargs):return {"ReservedConcurrentExecutions":2}
        cloud.lam=Lambda();cloud.check_concurrency=lambda:None;cloud.outputs=lambda name:{"TableName":cloud.name,"RuntimeRoleArn":"role","RepositoryUri":"repo","CandidateUrl":"https://candidate","CandidateVersion":"4"}
        applied=[];cloud.apply=lambda name,template,params:applied.append(dict(params))
        with patch.object(ops,"smoke",side_effect=RuntimeError("Failed candidate")):
            with self.assertRaises(RuntimeError):cloud.deploy("repo@sha256:abcd")
        self.assertEqual(len(applied),1);self.assertEqual(applied[0]["ProductionVersion"],"3")
    def test_deploy_rejects_quota_before_database_build_or_push(self):
        cloud=object.__new__(ops.Cloud);cloud.cfg={**ops.DEFAULTS,"SANKALPA_API_TOKEN":"x"*40}
        cloud.check_concurrency=Mock(side_effect=ValueError("Insufficient quota"))
        cloud.outputs=Mock();cloud.push=Mock();cloud.apply=Mock()
        with self.assertRaisesRegex(ValueError,"Insufficient quota"):cloud.deploy()
        cloud.outputs.assert_not_called();cloud.push.assert_not_called();cloud.apply.assert_not_called()
    def test_concurrency_preserves_unreserved_headroom_and_existing_reservation(self):
        cloud=object.__new__(ops.Cloud);cloud.cfg={**ops.DEFAULTS,"DEPLOY_CONCURRENCY":"2"};cloud.name="sankalpa-prod";cloud.lam=Mock()
        cloud.lam.get_function_concurrency.return_value={"ReservedConcurrentExecutions":0}
        for available in (10,100,101):
            cloud.lam.get_account_settings.return_value={"AccountLimit":{"UnreservedConcurrentExecutions":available}}
            with self.assertRaises(ValueError):cloud.check_concurrency()
        cloud.lam.get_account_settings.return_value={"AccountLimit":{"UnreservedConcurrentExecutions":102}}
        cloud.check_concurrency()
        cloud.lam.get_account_settings.return_value={"AccountLimit":{"UnreservedConcurrentExecutions":100}}
        cloud.lam.get_function_concurrency.return_value={"ReservedConcurrentExecutions":2}
        cloud.check_concurrency()
    def test_shared_concurrency_works_with_small_account_quota(self):
        cloud=object.__new__(ops.Cloud);cloud.cfg={**ops.DEFAULTS};cloud.lam=Mock()
        cloud.lam.get_account_settings.return_value={"AccountLimit":{"UnreservedConcurrentExecutions":10}}
        cloud.check_concurrency();cloud.lam.get_function_concurrency.assert_not_called()
        cloud.lam.get_account_settings.return_value={"AccountLimit":{"UnreservedConcurrentExecutions":0}}
        with self.assertRaises(ValueError):cloud.check_concurrency()
    def test_start_reconciles_shared_concurrency_by_removing_reservation(self):
        cloud=object.__new__(ops.Cloud);cloud.name="sankalpa-prod";cloud.lam=Mock()
        cloud.stack=lambda name:{"Parameters":[{"ParameterKey":"ReservedConcurrency","ParameterValue":"-1"}]}
        cloud.lam.get_function_concurrency.return_value={"ReservedConcurrentExecutions":0}
        cloud.update_parameters({"ReservedConcurrency":"-1"})
        cloud.lam.delete_function_concurrency.assert_called_once_with(FunctionName=cloud.name)
        cloud.lam.put_function_concurrency.assert_not_called()
    def test_rollback_republishes_current_credentials(self):
        cloud=object.__new__(ops.Cloud);cloud.name="sankalpa-prod"
        class Lambda:
            def get_alias(self,**kwargs):return {"FunctionVersion":"2"}
            def get_function(self,**kwargs):return {"Code":{"ResolvedImageUri":"repo@sha256:old"}}
        cloud.lam=Lambda();images=[];cloud.deploy=lambda image:images.append(image)
        cloud.rollback();self.assertEqual(images,["repo@sha256:old"])
    def test_stop_preserves_noecho_parameters(self):
        cloud=object.__new__(ops.Cloud);cloud.name="sankalpa-prod"
        cloud.stack=lambda name:{"Parameters":[{"ParameterKey":"ReservedConcurrency","ParameterValue":"2"},{"ParameterKey":"ApiToken","ParameterValue":"****"}]}
        captured=[]
        class Waiter:
            def wait(self,**kwargs):pass
        class Formation:
            def get_template(self,**kwargs):return {"TemplateBody":"template"}
            def create_change_set(self,**kwargs):captured.append(kwargs);return {"Id":"change"}
            def get_waiter(self,name):return Waiter()
            def execute_change_set(self,**kwargs):pass
        cloud.cf=Formation();cloud.update_parameters({"ReservedConcurrency":"0"})
        parameters=captured[0]["Parameters"]
        self.assertEqual(parameters[1],{"ParameterKey":"ApiToken","UsePreviousValue":True})
        self.assertNotIn("****",json.dumps(parameters))
    def test_teardown_refuses_unowned_resources_and_production(self):
        cloud=object.__new__(ops.Cloud);cloud.environment="staging"
        with self.assertRaises(ValueError):cloud.assert_resource_tags([{"Key":"Project","Value":"Other"},{"Key":"Environment","Value":"staging"}])
        cloud.environment="prod"
        with self.assertRaises(ValueError):cloud.destroy_staging()
    def test_resource_prefix_is_validated_and_selects_namespace(self):
        output=io.StringIO()
        with contextlib.redirect_stdout(output):ops.main(["setup","--target","aws","--plan","--set","DEPLOY_RESOURCE_PREFIX=sankalpa-personal"])
        self.assertEqual(json.loads(output.getvalue())["table"],"sankalpa-personal-prod")
        with self.assertRaises(ValueError):ops.main(["setup","--target","aws","--plan","--set","DEPLOY_RESOURCE_PREFIX=unrelated"])
    def test_release_state_separates_accounts_regions_targets_and_prefixes(self):
        base={**ops.DEFAULTS,"DEPLOY_ENVIRONMENT":"prod","DEPLOY_ACCOUNT_ID":"123456789012","_TARGET":"aws"}
        first=ops.state_path(base)
        for key,value in [("DEPLOY_ACCOUNT_ID","210987654321"),("DEPLOY_REGION","us-west-2"),("DEPLOY_RESOURCE_PREFIX","sankalpa-personal"),("_TARGET","local")]:
            self.assertNotEqual(first,ops.state_path({**base,key:value}))

@unittest.skipUnless(os.environ.get("SANKALPA_TEST_DYNAMODB_ENDPOINT"),"Requires isolated DynamoDB Local")
class LocalMigrationTests(unittest.TestCase):
    def test_sdk_import_validate_and_conditional_update(self):
        import boto3
        client=boto3.client("dynamodb",endpoint_url=os.environ["SANKALPA_TEST_DYNAMODB_ENDPOINT"],region_name="us-east-1",aws_access_key_id="local",aws_secret_access_key="local")
        table="sankalpa-test-import-"+uuid.uuid4().hex;ops.ensure_local_table(client,table)
        try:
            with tempfile.TemporaryDirectory() as temp:
                path=Path(temp)/"source.db";_,_,identity=source_file(path)
                with contextlib.redirect_stdout(io.StringIO()):ops.import_db(client,table,path)
                docs=ops.all_docs(client,table)
                self.assertEqual(docs["META"]["serviceInstanceId"],identity);self.assertEqual(ops.validate_documents(docs)["vows"],1)
        finally:client.delete_table(TableName=table)

if __name__=="__main__":unittest.main()
