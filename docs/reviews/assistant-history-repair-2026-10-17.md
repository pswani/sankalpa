# Historical observance repair: review and local verification

## Finding and resulting behavior

The screenshot request failed because the commitment began September 14 but the initial lifecycle
Begin was recorded October 17. The old tool feedback discarded the actual refusal, so the model
repeatedly asked for different daily times. Both deployed versions were current; this was a semantic
and recovery-design defect.

The assistant now proposes one explicit earlier-Begin correction with the 30 records through
October 13. Approval saves both together, retaining the original Begin in the audit. Day-based
observance can use a visibly suggested recording convention; supplied times are preserved. Linked,
paused, terminal, and previously corrected histories remain excluded. Finite coverage and the
30-entry transaction limit remain enforced.

See the [analysis, design, dry runs and implementation review](../design/conversational-batch-sessions/history-repair.md).

## Verification

| Check | Result |
|---|---|
| `backend/scripts/verify-aws-local.sh --container` | PASS: 146 Java tests, 81 operator tests, infrastructure lint; isolated real DynamoDB Local and container deployment/replacement/rollback/recovery/data retention |
| Final operator regression run | PASS: 82 tests, none skipped, against isolated DynamoDB Local; includes the new audit-export check and all 16 release-gate tests |
| Final primary Swift package | PASS: 226 tests (95 domain, 110 storage/application, 21 conversation) |
| `backend/scripts/verify_assistant_history.py` | PASS using the configured real provider and disposable local SQLite practice: screenshot flow → v3 preview → 30 records and one audit → replay without duplicates; follow-up without exact time → suggested-time preview for two days |

The backend suite exercises both actual SQLite migration/cold reload and actual AWS SDK transactions
against isolated DynamoDB Local. Fault injection proves entry-17 refusal rolls back Begin, audit,
sessions, and revision. The Dynamo adapter checks 96 actions with a fence; old-client confirmation
fails closed. Native tests cover capability headers, v3 preview validation/recovery, and audit mapping.

The real-provider utility makes model calls only; it never calls a deployed practice API. No production
practice data was modified, and these changes have not been deployed by this task. Deployment requires
the new backend and rebuilt iPhone app. Your existing release workflow remains in place, with its
candidate capability check extended to require the repair feature.

The second iPhone client also passed `app2/scripts/verify.sh`: 78 core/storage tests, all 8
simulator UI tests, and its physical-device Release configuration build (without signing).
Its local verification artifacts are under `app2/build/verification-20261017-224750/`.

The primary iPhone run `app/scripts/test.sh` passed all 24 simulator UI tests and its physical-device
Release configuration build (without signing). Its report is
`app/build/test-runs/2026-10-17-224414/report.md`. The run's initial package phase passed 225 tests;
the final independent package run passed 226 after adding the audit mapping/cache regression.
The Release build includes that final source. The follow-up Dynamo adapter review also passed all
12 tests after correcting the test fixture's lease timestamp units to epoch seconds.

Final review: no unresolved implementation defects found in the constrained repair flow. Physical
installation and production deployment were not performed. Real model behavior was sampled through
the isolated acceptance utility; deterministic tests enforce the authoritative mutation boundaries.

The app report generator's 8 Python tests also passed. Across the final distinct suites there are
572 passing tests: 146 backend, 82 operator, 226 primary Swift, 24 primary UI, 78 second-client Swift,
8 second-client UI, and 8 report-generator tests, plus both Release builds and container/infrastructure
verification. The real-provider acceptance is recorded separately from those deterministic counts.
