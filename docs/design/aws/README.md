# AWS Backend Deployment — Detailed Design

Status: implementation and local verification complete October 13, 2026. Live AWS and physical-device acceptance require a deployment.

The deployment uses one Spring Boot backend on AWS Lambda, an AWS-generated Function URL,
and DynamoDB. Local environment files supply configuration during deployment. The initial
architecture targets $1–$5/month of infrastructure cost for a small personal workload of
approximately 1,000 API requests per month, excluding model-provider charges.

The source of truth is the [AWS requirements](../../requirements/aws.md). Existing practice,
session reliability, linked-extension, and conversational contracts remain in force.

## Documents

| Document | Contents |
|---|---|
| [Detailed design](design.md) | Application changes, DynamoDB data and transaction model, iOS configuration, local/AWS lifecycle, migration, verification, and delivery order |
| [Implementation and review](implementation-review.md) | Delivered scripts, verification evidence, fixes, and remaining live acceptance |
| [AWS Console setup guide](aws-console-setup.md) | Account prerequisites, CloudFormation setup, resource settings, deployment, validation, operation, and troubleshooting |

## Selected decisions

- Keep Java 21, Spring Boot, the existing domain model, and existing REST paths.
- Package one application container with AWS Lambda Web Adapter.
- Use DynamoDB Standard with on-demand capacity and a new persistence transaction adapter.
- Use a stable Lambda Function URL attached to the `prod` alias.
- Read ignored environment files locally and supply Lambda environment variables.
- Use separate foundation and application CloudFormation stacks per environment.
- Retain production practice data when replacing or removing the application.
- Keep the assistant disabled for initial production verification; enable it after streaming
  and confirmation tests pass.

The initial deployment requires no Route 53 zone, custom domain, API Gateway, Secrets Manager,
RDS, NAT gateway, or customer VPC. `api.pswani.com` is deferred. A future custom-domain design
must account for the fronting service needed by a Function URL; a DNS record alone does not
give the Function URL a custom-hostname certificate.

## Implementation boundary

The adapters, scripts, configuration, container definitions, and templates now exist. See
[operator commands](../../../backend/scripts/README-aws.md) for the executable workflow.
The Console guide and automated setup use the same infrastructure templates.

This documentation does not modify the application, provision cloud resources, commit changes,
or perform a production cutover.
