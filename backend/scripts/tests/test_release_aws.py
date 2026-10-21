import argparse
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch

SCRIPTS=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(SCRIPTS))
import release_aws as release


def arguments(**changes):
    values=dict(target='aws',environment='prod',env_file=None,region=None,profile=None,
                set=[],full_ios=False,verify_only=False)
    values.update(changes)
    return argparse.Namespace(**values)


class ReleaseTests(unittest.TestCase):
    def test_mismatched_environment_file_is_refused_before_aws(self):
        with tempfile.TemporaryDirectory() as temporary:
            path=Path(temporary)/'staging.env';path.write_text('DEPLOY_ENVIRONMENT=staging\nSANKALPA_API_TOKEN=private-token\n')
            with patch.object(release.ops,'Cloud',side_effect=AssertionError('AWS called')):
                with self.assertRaisesRegex(ValueError,'Environment file does not match'):
                    release.main(['--env-file',str(path)])

    def test_matching_staging_plan_selects_staging_without_network(self):
        with tempfile.TemporaryDirectory() as temporary:
            path=Path(temporary)/'staging.env';path.write_text('DEPLOY_ENVIRONMENT=staging\n')
            output=io.StringIO()
            with patch.object(release.ops,'Cloud',side_effect=AssertionError('AWS called')),contextlib.redirect_stdout(output):
                release.main(['--environment','staging','--env-file',str(path),'--plan'])
            self.assertEqual(json.loads(output.getvalue())['environment'],'staging')

    def test_plan_has_no_cloud_docker_test_or_secret_output(self):
        with tempfile.TemporaryDirectory() as temporary:
            env=Path(temporary)/'prod.env';env.write_text('SANKALPA_API_TOKEN=private-plan-token\n')
            output=io.StringIO()
            with patch.object(release.ops,'Cloud',side_effect=AssertionError('AWS called')),patch.object(release.subprocess,'run',side_effect=AssertionError('Process called')),contextlib.redirect_stdout(output):
                release.main(['--plan','--env-file',str(env)])
            self.assertNotIn('private-plan-token',output.getvalue())
            self.assertEqual(json.loads(output.getvalue())['environment'],'prod')

    def test_test_environment_removes_live_credentials_and_model_configuration(self):
        with patch.dict(os.environ,{'AWS_PROFILE':'live','AWS_SESSION_TOKEN':'private','DEPLOY_AWS_PROFILE':'live','SANKALPA_LLM_API_KEY':'private','SANKALPA_ASSISTANT_ENABLED':'true'}):
            env=release.test_environment()
        self.assertNotIn('AWS_PROFILE',env);self.assertNotIn('AWS_SESSION_TOKEN',env)
        self.assertNotIn('DEPLOY_AWS_PROFILE',env)
        self.assertEqual(env['SANKALPA_LLM_API_KEY'],'')
        self.assertEqual(env['SANKALPA_LLM_PROVIDER'],'fake')
        self.assertEqual(env['AWS_ACCESS_KEY_ID'],'local')

    def test_fingerprint_detects_untracked_source_changes_but_ignores_generated_data(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary);source=root/'backend/src/main.java';source.parent.mkdir(parents=True);source.write_text('first')
            before=release.source_fingerprint(root)
            (source.parent/'__pycache__').mkdir();(source.parent/'__pycache__/ignored').write_text('cache')
            (root/'backend/.env.prod').write_text('secret')
            self.assertEqual(before,release.source_fingerprint(root))
            source.write_text('changed');self.assertNotEqual(before,release.source_fingerprint(root))
            before=release.source_fingerprint(root);(source.parent/'untracked.java').write_text('new')
            self.assertNotEqual(before,release.source_fingerprint(root))

    def test_capability_and_identity_gate_rejects_old_or_wrong_practice_candidate(self):
        valid={**release.REQUIRED_CAPABILITIES,'serviceInstanceId':'same'}
        release.check_capabilities(valid,'same')
        for value in [{**valid,'serviceInstanceId':'different'},{**valid,'assistantBatchSessions':None},{**valid,'assistantBatchSessions':True},{**valid,'assistantBeginCorrection':None},{**valid,'assistantBeginCorrection':True}]:
            with self.assertRaises(RuntimeError):release.check_capabilities(value,'same')

    def fixture(self, temporary, verify_only=False):
        args=arguments(verify_only=verify_only)
        cfg={**release.ops.DEFAULTS,'DEPLOY_ACCOUNT_ID':'123456789012','DEPLOY_ENVIRONMENT':'prod','SANKALPA_API_TOKEN':'x'*40,'_TARGET':'aws'}
        with patch.object(release.ops,'BACKEND',Path(temporary)):
            runner=release.Release(cfg,args)
        cloud=Mock();cloud.name='sankalpa-prod';before={'table':'sankalpa-prod','serviceInstanceId':'same','url':'https://stable','version':'1'}
        cloud.outputs.return_value={'ProductionUrl':'https://stable'}
        cloud.lam.get_alias.return_value={'FunctionVersion':'2'}
        return runner,cloud,before

    def run_mocked(self, runner, cloud, before, command=None, ids=None, fingerprints=None):
        capability={**release.REQUIRED_CAPABILITIES,'serviceInstanceId':'same'}
        with patch.object(release,'preflight',return_value=(cloud,before),side_effect=AssertionError('AWS called in verify-only') if runner.args.verify_only else None),patch.object(release,'source_fingerprint',side_effect=fingerprints or ['source']*4),patch.object(release.ops,'configuration',return_value=runner.cfg),patch.object(release.ops,'verify_domain'),patch.object(release.ops,'smoke',return_value=capability),patch.object(runner,'command',side_effect=command),patch.object(runner,'image_id',side_effect=ids or ['sha256:same']*2),contextlib.redirect_stdout(io.StringIO()):
            runner.run()

    def test_test_failure_stops_before_deploy(self):
        with tempfile.TemporaryDirectory() as temporary:
            runner,cloud,before=self.fixture(temporary)
            def fail(name,*args,**kwargs):
                if name=='backend-tests':raise RuntimeError('tests failed')
            with self.assertRaisesRegex(RuntimeError,'tests failed'):self.run_mocked(runner,cloud,before,command=fail)
            cloud.deploy.assert_not_called()

    def test_failed_exact_container_gate_stops_before_deploy(self):
        with tempfile.TemporaryDirectory() as temporary:
            runner,cloud,before=self.fixture(temporary)
            def fail(name,*args,**kwargs):
                if name=='container-tests':raise RuntimeError('image failed')
            with self.assertRaisesRegex(RuntimeError,'image failed'):self.run_mocked(runner,cloud,before,command=fail)
            cloud.deploy.assert_not_called()

    def test_source_change_or_retagged_image_stops_before_deploy(self):
        for changed in ('source','image'):
            with self.subTest(changed=changed),tempfile.TemporaryDirectory() as temporary:
                runner,cloud,before=self.fixture(temporary)
                with self.assertRaises(RuntimeError):
                    self.run_mocked(runner,cloud,before,ids=['sha256:same','sha256:other'] if changed=='image' else None,fingerprints=['source','modified'] if changed=='source' else None)
                cloud.deploy.assert_not_called()

    def test_happy_path_deploys_the_image_used_by_container_gate(self):
        with tempfile.TemporaryDirectory() as temporary:
            runner,cloud,before=self.fixture(temporary);commands=[]
            self.run_mocked(runner,cloud,before,command=lambda *args,**kwargs:commands.append(args))
            image=cloud.deploy.call_args.kwargs['source_image']
            gate=next(args[1] for args in commands if args[0]=='container-tests')
            self.assertEqual(gate[gate.index('--image')+1],image)
            self.assertEqual(runner.report['status'],'deployed')
            self.assertEqual(runner.report['url'],'https://stable')
            self.assertNotIn('x'*40,json.dumps(runner.report))
            self.assertEqual((runner.directory/'summary.json').stat().st_mode & 0o777,0o600)

    def test_verify_only_does_not_contact_cloud_or_validate_live_database(self):
        with tempfile.TemporaryDirectory() as temporary:
            runner,cloud,before=self.fixture(temporary,verify_only=True)
            self.run_mocked(runner,cloud,before)
            cloud.deploy.assert_not_called();self.assertEqual(runner.report['status'],'verified')

    def test_config_change_stops_release(self):
        with tempfile.TemporaryDirectory() as temporary:
            runner,cloud,before=self.fixture(temporary)
            with patch.object(release,'source_fingerprint',return_value='same'),patch.object(release.ops,'configuration',return_value={**runner.cfg,'SANKALPA_API_TOKEN':'rotated'}):
                with self.assertRaisesRegex(RuntimeError,'inputs changed'):runner.verify_source('same')

    def test_command_failure_records_failure(self):
        with tempfile.TemporaryDirectory() as temporary:
            runner,cloud,before=self.fixture(temporary)
            with contextlib.redirect_stdout(io.StringIO()):
                with self.assertRaises(RuntimeError):runner.command('failing',[sys.executable,'-c','raise SystemExit(3)'])
            self.assertEqual(runner.report['steps'][-1]['status'],'failed')

    def test_candidate_identity_or_contract_failure_never_promotes(self):
        from test_aws_backend import MemoryClient
        for mismatch in ('identity','capability'):
            with self.subTest(mismatch=mismatch):
                ops=release.ops;cloud=object.__new__(ops.Cloud)
                cloud.cfg={**ops.DEFAULTS,'SANKALPA_API_TOKEN':'x'*40};cloud.name='sankalpa-prod';cloud.environment='prod'
                cloud.db=MemoryClient();ops.init_db(cloud.db,cloud.name)
                identity=ops.get_doc(cloud.db,cloud.name,'META')['serviceInstanceId']
                cloud.check_concurrency=lambda:None
                cloud.stack=lambda name:{'Parameters':[]}
                cloud.lam=Mock();cloud.lam.get_alias.side_effect=lambda **kw:{'FunctionVersion':'3' if kw['Name']=='prod' else '2'}
                cloud.lam.get_function_concurrency.return_value={}
                cloud.outputs=lambda name:{'TableName':cloud.name,'RuntimeRoleArn':'role','RepositoryUri':'repo','CandidateUrl':'https://candidate','CandidateVersion':'4','ProductionUrl':'https://stable'}
                applied=[];cloud.apply=lambda name,template,params:applied.append(dict(params))
                capability={**release.REQUIRED_CAPABILITIES,'serviceInstanceId':identity if mismatch=='capability' else 'wrong'}
                if mismatch=='capability':capability.pop('assistantBatchSessions')
                with patch.object(ops,'smoke',return_value=capability):
                    with self.assertRaises(RuntimeError):
                        cloud.deploy(image='repo@sha256:abcd',candidate_check=lambda cap:release.check_capabilities(cap,identity))
                self.assertEqual(len(applied),1)
                self.assertEqual(applied[0]['ProductionVersion'],'3')

    def test_preflight_refuses_unprotected_production_and_stopped_service(self):
        for failure in ('protection','stopped'):
            with self.subTest(failure=failure):
                cloud=Mock();cloud.name='sankalpa-prod';cloud.outputs.return_value={'TableName':'sankalpa-prod','ProductionUrl':'https://stable'}
                cloud.stack.return_value={'StackStatus':'UPDATE_COMPLETE'}
                cloud.db.describe_table.return_value={'Table':{'DeletionProtectionEnabled':failure!='protection'}}
                cloud.db.describe_continuous_backups.return_value={'ContinuousBackupsDescription':{'PointInTimeRecoveryDescription':{'PointInTimeRecoveryStatus':'ENABLED'}}}
                cloud.lam.get_function_concurrency.return_value={'ReservedConcurrentExecutions':0}
                cfg={**release.ops.DEFAULTS,'SANKALPA_API_TOKEN':'x'*40,'DEPLOY_ENVIRONMENT':'prod'}
                with patch.object(release.ops,'Cloud',return_value=cloud),patch.object(release.ops,'all_docs',return_value={'META':{'serviceInstanceId':'same'}}),patch.object(release.ops,'validate_documents'):
                    with self.assertRaises(RuntimeError):release.preflight(cfg)
                cloud.deploy.assert_not_called()

    def test_post_deploy_failure_cannot_report_production_ready(self):
        with tempfile.TemporaryDirectory() as temporary:
            runner,cloud,before=self.fixture(temporary)
            cloud.outputs.return_value={'ProductionUrl':'https://changed'}
            with self.assertRaisesRegex(RuntimeError,'URL changed'):self.run_mocked(runner,cloud,before)
            self.assertNotEqual(runner.report['status'],'deployed')

if __name__=='__main__':unittest.main()
