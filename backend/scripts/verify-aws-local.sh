#!/bin/sh
# Real DynamoDB Local verification; never accesses an AWS account or practice database.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"
if [ ! -x .venv/bin/python ]; then ./scripts/bootstrap-tools.sh; fi
test_pid=
cleanup() { if [ -n "$test_pid" ]; then kill "$test_pid" 2>/dev/null || true; fi; }
trap cleanup EXIT INT TERM
if [ -z "${SANKALPA_TEST_DYNAMODB_ENDPOINT:-}" ]; then
    mkdir -p .tools/dynamodb
    if [ ! -f .tools/dynamodb/DynamoDBLocal.jar ]; then
        curl --fail --silent --show-error https://s3.us-west-2.amazonaws.com/dynamodb-local/dynamodb_local_latest.tar.gz -o .tools/dynamodb-local.tar.gz
        tar -xzf .tools/dynamodb-local.tar.gz -C .tools/dynamodb
    fi
    port=$(.venv/bin/python -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
    java -Djava.library.path=.tools/dynamodb/DynamoDBLocal_lib -jar .tools/dynamodb/DynamoDBLocal.jar -inMemory -sharedDb -port "$port" > .tools/dynamodb-test.log 2>&1 &
    test_pid=$!
    SANKALPA_TEST_DYNAMODB_ENDPOINT="http://127.0.0.1:$port"
    export SANKALPA_TEST_DYNAMODB_ENDPOINT
fi
.venv/bin/python - <<'PY'
import os,re,time,boto3
endpoint=os.environ['SANKALPA_TEST_DYNAMODB_ENDPOINT']
if not re.fullmatch(r'http://(127\.0\.0\.1|localhost):[0-9]+',endpoint): raise SystemExit('Test endpoint must be local')
client=boto3.client('dynamodb',endpoint_url=endpoint,region_name='us-east-1',aws_access_key_id='local',aws_secret_access_key='local')
for attempt in range(40):
    try:client.list_tables();break
    except Exception:time.sleep(.25)
else:raise SystemExit('DynamoDB Local did not start; inspect .tools/dynamodb-test.log')
PY
./scripts/verify.sh
.venv/bin/python -m unittest discover -s scripts/tests
.venv/bin/cfn-lint ../infra/foundation.yaml ../infra/application.yaml
if [ "${1:-}" = "--container" ]; then .venv/bin/python scripts/verify_container.py --skip-host-tests; fi
printf 'AWS local verification passed; test tables are isolated and removed.\n'
