# AWS Backend Deployment

Status: requirements captured October 9, 2026; implementation/local verification complete October 13, 2026. Live deployment acceptance is separately recorded.

## Purpose

Run the Sankalpa backend on AWS Lambda so that the connected iOS application can use it
without relying on a backend running on the user's Mac. Keep recurring cost low and retain
a complete local build, deployment, and testing workflow.

These requirements supplement the [Sankalpa requirements](sankalpa.md),
[linked extension requirements](linked-sankalpa-extensions.md), and existing reliability
and conversational contracts. They do not change practice rules or introduce multiple users.
The [AWS design](../design/aws/README.md) describes the selected implementation.

## Deployment and operation

| ID | Requirement |
|---|---|
| AWS-001 | The backend can be built, deployed, tested, inspected, and stopped locally. |
| AWS-002 | The same application release can be deployed locally or to AWS Lambda using target-specific configuration. |
| AWS-003 | Deployment accepts environment-specific account/profile, Region, resource names, database location, time zone, authentication, assistant settings, memory, timeout, and concurrency parameters. |
| AWS-004 | Repeated deployment to the same environment updates the existing managed deployment rather than creating another independent backend. |
| AWS-005 | A failed candidate release leaves the existing production release serving requests. |
| AWS-006 | The operator can stop new requests, restart service, and roll back to a compatible previous application release. Stopping does not delete practice data. |
| AWS-007 | The operator can clean up obsolete releases, images, local containers, and temporary environments while retaining resources needed by live or rollback releases. |
| AWS-008 | Replacement, stopping, and cleanup affect only resources owned by the selected Sankalpa environment. Unrelated processes and AWS resources are not stopped or deleted. |
| AWS-009 | Cloud infrastructure is reproducible from versioned definitions. Console setup and later scripted deployment use the same definitions. |
| AWS-010 | Local development, staging, and production use separate data and credentials. Mutation tests and demonstration seeds cannot target production by default. |

## Endpoint and iOS access

| ID | Requirement |
|---|---|
| AWS-011 | The connected iOS application consumes the existing REST API over trusted HTTPS. |
| AWS-012 | The initial deployment can use an AWS-generated endpoint without purchasing a domain or configuring a hosted DNS zone. |
| AWS-013 | Normal releases, rollback, and stop/start preserve the production endpoint address. Explicit destruction and recreation may change it and must report the new address. |
| AWS-014 | The client accepts an HTTPS service address without an explicit port and uses port 443. Existing explicit local-development addresses continue to work. |
| AWS-015 | Existing endpoint paths, wire formats, business error codes, service-instance headers, revision checks, linked-vow behavior, and supported client capabilities remain compatible. |

The originally proposed `api.pswani.com` address is deferred. A custom domain may be added
later; it is not required for the initial low-cost deployment. This work applies to the
connected client under `app/`; the independent local-file client under `app2/` is outside scope.

## Authentication and configuration

| ID | Requirement |
|---|---|
| AWS-016 | Every production practice and assistant endpoint requires the application bearer credential. Production cannot start with missing or blank authentication configuration. |
| AWS-017 | Local environment files can supply deployment configuration and secrets without requiring a separately charged secret-management service. Different environments can select different files. |
| AWS-018 | Secrets are excluded from source control, ordinary command output, and operational logs. The application artifact can be reused across environments when configuration is supplied separately. |
| AWS-019 | AWS database access uses the Lambda execution role. Static AWS access keys are not required in the application or iOS client. |
| AWS-020 | Updating a credential and rolling back an application release have documented behavior. Rollback must not silently restore a credential the operator has revoked. |

The user accepts secrets in a private bundled `.env` file. The selected design instead reads
the local file during deployment and supplies Lambda environment variables, meeting the same
cost objective while keeping the application image reusable. Bundling secrets is not required.

## Persistence, reliability, and recovery

| ID | Requirement |
|---|---|
| AWS-021 | Practice records, lifecycle histories, sessions, deletion identities, and assistant proposals survive Lambda cold starts, deployment, and concurrent execution. |
| AWS-022 | Each business mutation preserves its existing atomicity and replay guarantees across independent execution environments. |
| AWS-023 | Reads and paginated refreshes detect concurrent changes instead of returning an apparently consistent mixture of revisions. |
| AWS-024 | One persisted practice has a stable service-instance identity across Lambda instances and application versions. A new empty practice has its own identity. |
| AWS-025 | Existing SQLite data can be backed up, migrated, verified, and cut over while preserving IDs, revisions, linked relationships, histories, deleted-session identities, and proposal replay records. Incomplete migration cannot serve normal requests. |
| AWS-026 | Production has a documented backup and restore procedure. Application rollback is distinguished from database recovery. |

## Assistant, cost, and observability

| ID | Requirement |
|---|---|
| AWS-027 | When enabled, the assistant preserves the existing HTTP/SSE protocol and confirmation semantics. Incremental events reach the phone through the deployed endpoint. |
| AWS-028 | Assistant concurrency and usage controls work across execution environments. Provider calls and mutations do not rely on work continuing after a Lambda invocation finishes. |
| AWS-029 | The initial architecture targets approximately $1–$5/month of AWS infrastructure cost at 1,000 small API calls, modest execution times, and a small personal dataset. This is an estimate, not a guaranteed bill or hard spending cap. |
| AWS-030 | Infrastructure estimates identify storage, artifacts, logs, backups, and transfers as well as request charges. Model-provider costs, optional domain renewal, taxes, and unrelated workloads are separate. |
| AWS-031 | The operator can inspect deployment identity, health, endpoint, version, logs, and errors. Log retention and artifact cleanup bound unnecessary storage growth. Logs exclude credentials, practice text, request bodies, and assistant transcripts. |
| AWS-032 | Verification covers the existing contracts, local persistence, concurrent mutations, migration, AWS authentication and streaming, physical-device access, deployment failure, stop/start, rollback, and cleanup. |

## Acceptance boundary

The deployment is complete when the connected iOS application can reliably use the AWS
endpoint, the same release can be exercised locally, managed lifecycle operations work without
practice-data loss, and the observed resource configuration matches the cost design.

This document authorizes the design scope. It does not represent a deployed system or test
evidence. Acceptance evidence must be recorded during implementation.
