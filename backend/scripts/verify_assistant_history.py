#!/usr/bin/env python3
"""Opt-in real-provider acceptance check; only a disposable local SQLite practice is changed.

Run after ./scripts/verify.sh. Reads provider settings from --provider-env (default .env.prod),
never prints credentials, never calls an AWS practice API, and retains synthetic SSE evidence.
"""
import argparse
import os,json,time,uuid,subprocess,tempfile,urllib.request,pathlib,socket
root=pathlib.Path(__file__).resolve().parents[2]
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--provider-env',type=pathlib.Path,default=root/'backend/.env.prod')
options=parser.parse_args()
jar=root/'backend/target/sankalpa-backend-1.0.0-SNAPSHOT.jar'
if not jar.is_file(): raise SystemExit('Build the executable jar with backend/scripts/verify.sh first.')
with socket.socket() as reservation:
 reservation.bind(('127.0.0.1',0)); port=reservation.getsockname()[1]
scratch=pathlib.Path(tempfile.mkdtemp(prefix='sankalpa-repair-live-'))
env=dict(os.environ)
for line in options.provider_env.read_text().splitlines():
 if '=' in line and not line.startswith('#'):
  k,v=line.split('=',1)
  if k.startswith('SANKALPA_LLM_'):env[k]=v.strip().strip('\"').strip("'")
env.update(SANKALPA_TIMEZONE='America/Chicago',SANKALPA_PERSISTENCE='sqlite',SANKALPA_DEPLOYMENT='local',SANKALPA_DB_URL='jdbc:sqlite:'+str(scratch/'practice.db'),SANKALPA_ASSISTANT_ENABLED='true',SANKALPA_API_TOKEN=str(uuid.uuid4()),PORT=str(port))
log=(scratch/'server.log').open('w'); proc=subprocess.Popen(['java','-jar',str(jar)],cwd=scratch,env=env,stdout=log,stderr=log)
base=f'http://127.0.0.1:{port}/api/v1'; headers={'Authorization':'Bearer '+env['SANKALPA_API_TOKEN'],'Content-Type':'application/json'}
def call(path,body=None):
 req=urllib.request.Request(base+path,data=None if body is None else json.dumps(body).encode(),headers=headers)
 with urllib.request.urlopen(req,timeout=40) as r:
  data=r.read().decode()
  return data if 'text/event-stream' in r.headers.get('Content-Type','') else json.loads(data)
def uid():return str(uuid.uuid4())
try:
 for i in range(100):
  try: cap=call('/capabilities');break
  except Exception:time.sleep(.2)
 else:raise RuntimeError('Local startup failed; inspect '+str(scratch/'server.log'))
 headers.update({'Sankalpa-Service-Instance':cap['serviceInstanceId'],'Linked-Sankalpa-Version':'1','X-Sankalpa-Assistant-Batch-Sessions':'1','X-Sankalpa-Assistant-Begin-Correction':'1'})
 v=call('/sankalpas',dict(title='Brahmacharya',description='Synthetic regression',actionType='OBSERVANCE',startDate='2026-09-14',periodUnit='DAY',timesPerPeriod=1,periodCount=32)); vid=v['id'];call('/sankalpas/'+vid+'/begin',dict(effectiveAt='2026-10-17T18:08:54.846005440'))
 thread=uid()
 messages=[('user','I have observed the brahmacharya everyday since 9/14/2026. Can you please update the sankalpa accordingly?'),('assistant','Please choose the first 30 days, September 14 through October 13, or the remaining days.'),('user','Till October 13'),('assistant','What local time should I use for each day?'),('user','12:01 AM sounds good')]
 body=dict(threadId=thread,runId=uid(),state={},messages=[dict(id=uid(),role=r,content=t) for r,t in messages],tools=[],context=[],forwardedProps={})
 result=call('/assistant/runs',body);(scratch/'conversation.sse').write_text(result)
 events=[json.loads(line[5:]) for line in result.splitlines() if line.startswith('data:')]
 finish=next(e for e in events if e.get('type')=='RUN_FINISHED');out=finish['outcome'];item=out['interrupts'][0];meta=item['metadata'];assert meta['proposalVersion']==3;assert len(meta['batch']['entries'])==30;assert meta['batch']['beginAdjustment']['correctedEffectiveAt'].startswith('2026-09-14T00:01')
 confirm=dict(threadId=thread,runId=uid(),state={},messages=[],tools=[],context=[],forwardedProps={},resume=[dict(interruptId=item['id'],status='resolved',payload=dict(decision='confirm',confirmationId=uid()))])
 (scratch/'confirmation.sse').write_text(call('/assistant/runs',confirm))
 history=call('/sankalpas/'+vid+'/lifecycle-history');assert len(history[0]['beginCorrections'])==1;print('Confirmed audit verified',flush=True)
 (scratch/'replay.sse').write_text(call('/assistant/runs',dict(confirm,runId=uid())))
 import sqlite3
 with sqlite3.connect(scratch/'practice.db') as db: assert db.execute('select count(*) from practice_session').fetchone()[0]==30
 print('PASS: real model, 30 sessions, audit, replay without duplicates',flush=True)
 body2=dict(threadId=uid(),runId=uid(),state={},messages=[dict(id=uid(),role='user',content='For Brahmacharya I observed every day October 14 through October 15, 2026. Please record the missing days. I do not know an exact time of day.')],tools=[],context=[],forwardedProps={})
 fresh=call('/assistant/runs',body2);(scratch/'natural.sse').write_text(fresh)
 events2=[json.loads(line[5:]) for line in fresh.splitlines() if line.startswith('data:')]
 out2=next(e for e in events2 if e.get('type')=='RUN_FINISHED')['outcome']
 b=out2['interrupts'][0]['metadata']['batch'];assert len(b['entries'])==2;assert b['plan']['recordingTimeSuggested'];assert len(b['skippedDays'])==0
 print('PASS: natural observance request suggests a recording convention and only two missing days',flush=True)
 print('Synthetic artifacts:',scratch,flush=True)
finally:
 proc.terminate();proc.wait(timeout=15);log.close()
