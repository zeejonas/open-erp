## 1. Public contracts and durable schema

- [ ] 1.1 Define the exact event catalog, version 1 envelope, allowlisted resource summaries and source-read/company-context metadata; add contract tests for supported types, null fields and sensitive-value exclusion.
- [ ] 1.2 Add business event/stream/dispatch models and one create migration each, transactional revision allocation, exact payload-byte storage, digest and append-only constraints; test concurrent allocation, rollback and runtime tampering rejection.
- [ ] 1.3 Add subscription/revision/secret-reveal models and create migrations with tenant foreign keys, immutable history, disabled reason, `failingSince` and secret redaction; extend schema/audit tests for cross-tenant references and ciphertext exclusion.
- [ ] 1.4 Add delivery and delivery-ledger models/create migrations, `(organization_id, event_id, subscription_id)` uniqueness and partial indexes over unfinished work; test duplicate deliveries, one start/result per attempt and append-only evidence.
- [ ] 1.5 Let `createChangeTrigger` take the captured operations; attach insert/delete-only capture to `webhook_deliveries`, none to `business_event_dispatches`, and extend the audit coverage test and `audit-verify` to enforce exactly that scope.

## 2. Event production at business boundaries

- [ ] 2.1 Implement the event writer inside audited transactions writing the event and its dispatch record only; test rollback and that the write path issues no subscription reads.
- [ ] 2.2 Emit organization/company/role/group/approval-policy events through shared apply operations, including affected relationship removals; add parameterized operation tests proving one semantic event per logical transition and no timestamp-only/no-op update events.
- [ ] 2.3 Cover provisioning/template creation, organization restoration, membership creation/removal and group relationships outside ordinary apply paths; test attribution, actual relationship IDs, company-context rules and revision continuity after restoration.
- [ ] 2.4 Emit invitation issued/reissued/accepted/revoked events at usable business transitions; test held token preparation, approval release, rejection/withdrawal/failure and acceptance without leaking identity/token fields.
- [ ] 2.5 Emit approval request/decision/outcome/override events from success and separate failure transactions, including operator overrides; test final-approval races, failed application, persisted decisions and absence of rolled-back target events.
- [ ] 2.6 Add the audited-table event classification and the coverage test that fails on unclassified mapped tables or untested catalog entries.

## 3. Authorization and subscription lifecycle

- [ ] 3.1 Add the webhook permission catalog, explicit gateability exclusions and payload/secret-read viewer-template exceptions; test permission discovery and provisioned templates.
- [ ] 3.2 Add tenant subscription create/read/list/version APIs with strict validation, disabled creation, source/payload grants and concurrent quota enforcement; test missing permissions, cross-tenant IDs/scopes, non-member access and list parameter behavior.
- [ ] 3.3 Extend ProposedChange serialization/check/apply for subscription create/update/delete and all declared update fields; test held activation, stale revisions, lost requester authority, field-specific policies and at-most-once final application.
- [ ] 3.4 Implement immediate audited emergency disable, current-authority checks and cancellation entries for URL/scope revocation; test that shutdown is never held, in-flight requests can finish, queued work is not redirected, and name/rotation changes do not cancel authorized work.
- [ ] 3.5 Integrate organization deletion/restoration with subscription disablement and delivery cancellation in consistent lock order; test that deletion sends no later notification and restoration does not reactivate or revive canceled deliveries.

## 4. Secrets and restricted outbound transport

- [ ] 4.1 Add webhook key configuration, per-subscription `whsec_` secret generation and authenticated AES-GCM storage through Swift Crypto; test missing/malformed configuration, wrong tenant/secret binding, secret-safe errors and absence of secrets in DTOs/audit/logs/proposed changes.
- [ ] 4.2 Implement immediate `rotateSecret` and `POST /webhook-subscriptions/:id/secret` with its reveal record and `no-store`; test permission denial, reveal attribution, failure to record withholding the secret, and post-rotation signing.
- [ ] 4.3 Declare the locked AsyncHTTPClient dependency explicitly and implement vetted-address delivery using documented dnsOverride with original-host TLS/SNI, redirects disabled and bounded client lifetime; prove blocked IPv4/IPv6/metadata addresses, DNS rebinding resistance, hostname verification, redirect refusal and client shutdown with a focused transport/TLS fixture.
- [ ] 4.4 Sign retained body bytes with Standard Webhooks `v1` HMAC-SHA256, stable event identity, fresh timestamps and unique attempt IDs; verify against the Standard Webhooks reference test vectors, plus tamper and byte-identical retry checks.

## 5. Worker dispatch, claims, recovery and scheduling

- [ ] 5.1 Implement the dispatcher: SKIP LOCKED batch claims, revision-at-`occurredAt` matching, delivery insert and dispatch delete in one transaction; test no retrospective delivery, disable-before-dispatch, company filters, crash re-run idempotency and competing dispatchers.
- [ ] 5.2 Implement short SKIP LOCKED delivery claims, lease tokens, authorization-before-send and started entries, with subscription-before-delivery lock order; test competing workers, revoked work and no database transaction spanning HTTP I/O.
- [ ] 5.3 Enforce configured pool-wide limits through shared lease state and brief advisory locking; validate limit ordering at startup; test multiple worker instances, lease expiry, unhealthy endpoint isolation and progress for another organization.
- [ ] 5.4 Implement HTTP outcome classification, append-only results and jittered 72-hour retry scheduling including bounded Retry-After; use an injected clock/transport to test retryable versus terminal statuses, deadline exhaustion and worker downtime before first attempt.
- [ ] 5.5 Implement `failingSince` tracking and automatic pause; test full-window failure, single terminal rejection, intermittent success, queued-work cancellation and re-enable clearing.
- [ ] 5.6 Implement expired-attempt recovery and fenced completion; test a crash after remote acceptance, immutable unknown outcomes, stale-owner results and safe retry with the original event identity.
- [ ] 5.7 Register webhook-worker as an independent AsyncCommand running both loops, apply safe-role checks, isolate it from HTTP/OIDC startup and add bounded cancellation/shutdown; test command startup without OIDC, unsafe production credentials and pending-work recovery after restart.

## 6. Customer APIs

- [ ] 6.1 Add paginated event catalog/history and separate payload inspection using declared filters/orders; test metadata redaction, payload denial, tenant totals, invalid/repeated filters and stable paging.
- [ ] 6.2 Add delivery/attempt history, health and payload endpoints with bounded operational warnings; test joined attempt outcomes, cancellation reasons, queue-age/exhaustion/auto-pause attention flags and isolation/redaction.

## 7. Deployment, documentation and acceptance

- [ ] 7.1 Add the Compose worker service and API/worker key and limit injection without committed production keys; validate Compose configuration and demonstrate independently stopped API/worker processes, durable backlog and catch-up.
- [ ] 7.2 Run and record a throughput demo with a slow test endpoint under default limits, two worker replicas and a backlog, confirming the global-limit ceiling and cross-tenant fairness.
- [ ] 7.3 Publish webhook schemas/routes in offline OpenAPI export and document receiver verification with Standard Webhooks libraries, idempotency, filter gaps, auto-pause and re-enable, secret retrieval/rotation, customer role capabilities and acknowledgment versus downstream processing.
- [ ] 7.4 Document fresh pre-release migration, encryption-key backup, egress restrictions and forward recovery; preserve all existing migration/operational-command independence tests.
- [ ] 7.5 Run the focused webhook, approval, permission, audit/schema, runtime and OpenAPI suites, then the repository's required checks; resolve failures and validate the OpenSpec change before marking implementation complete.
