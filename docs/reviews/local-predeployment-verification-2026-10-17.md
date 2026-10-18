# Local predeployment verification — October 17, 2026

Result: **PASS**. All local checks completed successfully against the working tree based on
`6cc9065`, including the uncommitted batch-session changes. No implementation fixes or test retries
were needed during this rerun. Production AWS resources and practice data were not modified.

## Test results

| Suite | Tests | Result |
|---|---:|---|
| Backend clean Maven verification, including real DynamoDB Local SDK/HTTP integration | 134 | Passed, no skips |
| AWS deployment/operator script unit tests | 65 | Passed |
| App reporting-script unit tests | 8 | Passed |
| Primary app Swift domain, storage/application, and conversation tests | 223 | Passed |
| Primary app simulator screen and journey tests | 24 | Passed |
| App2 Swift domain and storage tests | 78 | Passed |
| App2 simulator UI tests | 8 | Passed |
| **Total** | **540** | **No failures** |

Additional gates passed: both CloudFormation templates; disposable ARM64 container build and local
deployment; replacement and rollback; failed-candidate recovery; stop/start; cleanup and retained
data/identity; both native Release builds; and `git diff --check`.

## Reproduction

```sh
# backend: starts its own isolated in-memory DynamoDB Local instance
./scripts/verify-aws-local.sh --container

# workspace root: isolated fixture backends and the dedicated test simulator
TOUR_PORT=18841 JOURNEY_PORT=18842 SANKALPA_ASSISTANT_ENABLED=false ./app/scripts/test.sh
./app2/scripts/verify.sh
python3 -m unittest discover -s app/scripts -p 'test_*.py'
```

The primary Swift count includes 19 XCTest conversation/protocol tests in addition to the
95 domain and 109 storage/application tests reported by Swift Testing.

## Evidence

- [Backend verification summary](../../backend/logs/latest-summary.md)
- [Primary app test report](../../app/build/test-runs/2026-10-17-205222/report.md)
- [Primary app structured results](../../app/build/test-runs/2026-10-17-205222/results.json)
- [App2 core test log](../../app2/build/verification-20261017-205232/core.log)
- [App2 UI test log](../../app2/build/verification-20261017-205232/ui.log)
- [App2 Release build log](../../app2/build/verification-20261017-205232/release.log)

The combined AWS workflow log is `/tmp/sankalpa-predeploy-backend.log`; the native workflow logs
are `/tmp/sankalpa-predeploy-app.log` and `/tmp/sankalpa-predeploy-app2.log`.
Temporary container namespaces, tables, fixture backends, and the disposable app2 simulator are
cleaned up by the verification scripts. Generated reports/build artifacts are local and may be
pruned by later verification runs.

## Deployment interpretation

No local deployment blockers were found. This validates local code, infrastructure templates, and
the production container shape; it does not claim a live AWS deployment or a live model-provider
evaluation. Run the normal AWS readiness/smoke check after deploying. Batch confirmation also
requires installing the updated primary iOS app because the feature is version-negotiated.
