## Why

Organizations need reliable notifications of committed ERP changes and approval outcomes without polling or coupling API availability to external endpoints. The existing atomic audit trail supplies database evidence; a public business-event contract and durable delivery evidence make those changes usable by integrations and traceable by controllers and auditors.

## What Changes

- Capture versioned, organization-owned business events and a dispatch record in the same Postgres transaction as supported business operations, including approval application and operational commands. Subscriber fan-out happens in the worker, so business-write cost does not grow with subscriber count.
- Add organization-owned webhook subscriptions with explicit event/company scopes, immutable configuration revisions, approval-gateable activation and changes, immediate emergency disable, and immediate secret rotation.
- Run a separate, horizontally scalable `webhook-worker` process from the existing Swift application/image. It fans events out to matching subscriptions, claims committed work with per-process concurrency and pool-wide per-subscription/per-organization limits so capacity grows with replicas, sends Standard Webhooks HMAC-signed HTTPS notifications, retries failures, and records append-only attempt evidence.
- Automatically pause subscriptions whose endpoint has failed continuously for 72 hours, attributed to the system and visible in health.
- Expose an event catalog, event and delivery history, integration health, restricted payload inspection, and recorded secret disclosure.
- Preserve the distinction between recorded approval decisions, successfully applied changes, endpoint acknowledgments, and downstream processing.
- **BREAKING (deployment configuration):** API serving and webhook workers require a deployment-provided webhook key-encryption key. Offline OpenAPI export and migration commands remain independent of it.

## Capabilities

### New Capabilities

- `business-events`: Public event catalog, payload schemas, atomic production, resource revisions, attribution, and producer-coverage tests.
- `webhook-subscriptions`: Tenant-scoped subscription management, approved outbound authority, immutable revisions, payload access, safe destinations, and secret management/disclosure.
- `webhook-delivery`: Dispatch fan-out, separate workers, signed requests, retries, automatic pause, attempt evidence, and health visibility.

### Modified Capabilities

- `approval-workflows`: Gate subscription changes, expose their editable fields, and exclude emergency disable, automatic pause and secret disclosure from approval gating.
- `organization-rbac`: Add webhook permissions and prevent automatic viewer-template access to payloads and secrets.
- `audit-trail`: Exclude secret ciphertext and duplicated event payloads from audit snapshots; narrow capture on the two operational queue tables to evidence-bearing operations.
- `database-access-control`: Apply the safe runtime-role startup check to the continuous delivery worker as well as the API.
- `service-runtime`: Define the worker command, key and limit configuration, production role checks, and independent process operation.

## Impact

- Extend application write services, `ProposedChange`, approval application/failure/override paths, organization provisioning/restoration, invitation acceptance, and applicable CLI operations.
- Add Fluent models/create migrations, tenant foreign keys, immutable evidence constraints, controllers/DTOs, OpenAPI contracts, worker services, Compose configuration, and operational documentation.
- Reuse Postgres, Vapor commands/client, SQLKit, and Swift Crypto; declare the existing transitive AsyncHTTPClient package explicitly for destination-safe delivery. No broker, Redis, or cloud-specific service is required.
- SOX/SOC: explicit outbound grants and tenant isolation; approval-gateable integration changes; recorded secret disclosure; immutable attribution, configuration, and delivery evidence; automatic containment of failing integrations. Transport acknowledgments do not establish downstream financial processing or compliance certification.

## Non-goals

- Kafka or any non-HTTPS transport, direct customer broker access, event sourcing, arbitrary workflow execution, inbound business webhooks, UI implementation, global or per-subscription event ordering, and exactly-once external side effects.
- Deferred to a follow-up change: approval-gated replay, synthetic test deliveries, the cross-table evidence API, `webhook-verify` audit/event/delivery reconciliation, graceful dual-signed secret rotation, and scaling work gated on measured signals: per-subscription concurrency settings, HTTP connection reuse, batch claims, reduced audit capture on append-only tables, and delivery archival/partitioning.
- New business restore/purge capabilities, new financial modules, automatic publication of every table, retrospective delivery to new subscriptions, downstream processing receipts, and automatic evidence deletion.
- Managed immutable archive infrastructure or deployment-specific SOX retention policy; evidence is retained indefinitely until separately specified.
