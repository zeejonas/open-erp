## Context

The API uses Swift/Vapor, Fluent/Postgres, explicit organization permissions, and audited transactions. `audit.capture_change()` records row evidence, including SQLKit writes. A soft delete can produce two row changes. `ApprovalService` can hold a write, record several decisions, apply it later, or roll application back and persist a failure separately. These are unsuitable boundaries for blindly forwarding row or HTTP events.

Organizations need a supported integration contract. Administrators need controlled outbound data authority; developers need schemas and diagnostics; operators need recovery; controllers need to connect authorization and changes to delivery evidence. The backend capabilities stand independently of any customer UI.

## Goals / Non-Goals

**Goals:** atomic business-event capture with a write path whose cost does not grow with subscriber count; organization-owned subscriptions; a separately deployable, horizontally scalable delivery worker; bounded retries with possible duplicates; automatic pausing of persistently failing endpoints; explicit payload and secret access; approval and emergency controls; durable delivery evidence.

**Non-Goals:** those in proposal.md, especially Kafka or any second transport, event sourcing, global ordering, exactly-once external processing, and a claim that endpoint acknowledgment establishes financial processing. Replay, synthetic tests, the cross-table evidence API, `webhook-verify` reconciliation and graceful secret rotation are deferred to a follow-up change (see Deferred Scope).

## Decisions

### 1. Application operations create semantic events inside existing transactions

Introduce a typed event catalog and an event writer used by shared business operations. `ProposedChange.apply`, provisioning, invitation acceptance/reissue, organization restoration, approval decisions/outcomes, and affected operational commands call it using the database supplied to `auditedTransaction`. Emit only the catalog's logical transitions, once per affected logical resource; do not emit on timestamp-only/no-op updates. Template provisioning may create ordinary resource events, but subscribers do not exist yet.

Record business events even with no subscriptions. Generate an event ID before inserting the event; retain the transaction ID, request ID, actor context, requester ID where applicable, and approval request ID internally. Link audit evidence by organization and transaction ID, allowing one business event to relate to multiple audit rows. Do not expose database session details in public event bodies.

Approval decisions receive their own events when persisted. Final application produces target-resource events plus `approval_request.applied`. A rollback leaves neither target events nor dispatch work; the existing separate failure transaction emits persisted decisions and `approval_request.failed`. Override is separately identifiable even when application fails. A held invitation is not publicly `issued` until usable; token generation/storage alone is not that business transition.

Framework basis: [Fluent transactions](https://docs.vapor.codes/fluent/transaction/) require using the closure's database and roll back its writes together; [Fluent lifecycle hooks](https://docs.vapor.codes/fluent/model/#lifecycle) describe model operations, not outer transaction commits.

Rejected: route-response publication, which misses CLI writes and misrepresents held changes; raw audit forwarding, which couples customers to storage and exposes excess data; external sends from model hooks, which can precede commit.

### 2. Postgres outbox with worker-side fan-out

The business transaction writes exactly two rows beyond its own changes: the immutable event and one `business_event_dispatches` row referencing it. It does not read subscriptions or create deliveries, so write latency and lock footprint do not grow with an organization's subscriber count. Any failure rolls back the whole operation.

A dispatcher loop in `webhook-worker` claims dispatch rows with `FOR UPDATE SKIP LOCKED` in bounded batches. For each event it selects, per non-deleted subscription in the organization, the latest revision whose `createdAt` is at or before the event's `occurredAt`. If that revision is enabled and its event/company scopes cover the event, and the subscription is not currently disabled, it inserts one delivery pinned to that revision. It then deletes the dispatch row in the same transaction. Matching against the revision in effect when the event occurred means a subscription enabled or widened later never receives earlier events. `occurredAt` and revision `createdAt` both use the database transaction timestamp. A uniqueness constraint on `(organization_id, event_id, subscription_id)` makes a re-run dispatch idempotent.

```text
API or command                  Postgres                       webhook-worker
authorize/apply ──transaction──▶ business rows + audit
                                business event
                                dispatch row
return after commit                                           dispatcher: claim dispatch rows,
                                                              match revisions, insert deliveries
                                                              sender: claim due deliveries,
                                                              signed HTTPS POST,
                                                              append entry, retry/finish
```

Workers poll with a configurable interval (default 1 s) against partial indexes, so an idle poll is an index probe. Use these public, organization-scoped tables, each with its own create migration:

| Table | Mutability and purpose |
|---|---|
| `business_event_streams` | Counter keyed uniquely by organization, resource type and resource ID; locked to allocate monotonically increasing emitted-event revisions |
| `business_events` | Append-only event metadata, payload bytes, SHA-256 digest and evidence linkage |
| `business_event_dispatches` | Transient fan-out queue: one row per undispatched event, deleted by the dispatcher |
| `webhook_subscriptions` | Soft-deletable identity, current revision, disabled reason/attribution, `failingSince` |
| `webhook_subscription_revisions` | Append-only configuration snapshot, approved scopes, secret ID and encrypted signing secret |
| `webhook_secret_reveals` | Append-only record of each secret disclosure: subscription, secret ID, actor, request ID |
| `webhook_deliveries` | Mutable scheduling state: pinned revision, event, state, next attempt time, lease token/expiry, attempt count |
| `webhook_delivery_entries` | Append-only ledger: attempt started, attempt result, and cancellation entries |

All IDs are UUIDs. Use required `organization_id`, composite tenant foreign keys, and database constraints on matching event/subscription/revision ownership. Evidence tables reject update/delete/truncate through the existing append-only mechanism. Resource revisions count emitted events, not every audit row. Lock/initialize the stream row and allocate its revision in the transaction. `changedFields` contains public business field names, not audit metadata columns.

Audit capture is scoped to evidence, not queue churn. `webhook_deliveries` scheduling updates (lease, state, next attempt, count) happen several times per attempt and are fully reconstructable from the append-only ledger, so its audit trigger captures only `INSERT` and `DELETE`. `business_event_dispatches` holds only an event reference and is created/deleted once per event; it is exempt from row capture, and the event it references is itself audited on insert. Every other new table keeps full trigger coverage. Delivery-history indexes are partial on `(next_attempt_at)` for `pending`/`retrying` rows so claim cost does not grow with retained history. Partitioning or archiving terminal deliveries is a later, separately proposed change.

Framework basis: [Fluent schemas](https://docs.vapor.codes/fluent/schema/) for models, unique constraints and migration structure; existing tenant-FK helpers for compound references; SQLKit for Postgres locking. [Postgres documents `SKIP LOCKED` for queue-like workloads](https://www.postgresql.org/docs/current/sql-select.html#SQL-FOR-UPDATE-SHARE) and [partial indexes](https://www.postgresql.org/docs/current/indexes-partial.html) for indexing a hot subset.

Rejected: fan-out inside the business transaction, which makes every business write read subscriptions and insert N rows with audit triggers; `LISTEN`/`NOTIFY` wake-ups, because a `NOTIFY` in every business transaction serializes commits on the notification queue and polling a partial index is cheap at the target latency; Postgres plus a direct broker publish as dual writes, which leaves a loss window; an in-memory queue, which loses pending work on restart.

### 3. Freeze a small public envelope and allowlisted resource summaries

Serialize each event once as UTF-8 JSON with `id`, `type`, `schemaVersion`, `occurredAt`, `organizationId`, nullable `companyId`, `resource` (`type`, `id`, `revision`), `actor` (`type`, nullable `id`), nullable `requestedById`, `requestId`, `approvalRequestId`, `changedFields`, and typed `data`. Retain the exact bytes for sends; retain a digest separately for evidence. Resource and relationship event types/summaries are enumerated in the business-events spec. Optional envelope fields are present as null when unavailable. New incompatible bodies require a new schema version.

Each subscription revision pins schema version 1. A future incompatible schema requires explicit subscription opt-in and a separately designed compatibility path.

The body contains resource summaries and references, not arbitrary full model DTOs. Exclude tokens, identity subjects, IPs, database usernames, operator names, approval comments, held change bodies, secrets, and raw exception messages. Do not include invitation email/name fields in the first contract. Metadata list endpoints omit `data` and exact bytes; a separate permission controls payload inspection.

Framework basis: [Vapor Content](https://docs.vapor.codes/basics/content/) for typed contracts and [Vapor validation](https://docs.vapor.codes/basics/validation/) for requests; retain encoded bytes instead of re-encoding during delivery.

Rejected: unrestricted old/new snapshots, which export sensitive data and bind contracts to schema; re-reading a resource at delivery time, which can send a later state.

### 4. Subscriptions carry durable organization authority

All new routes use the existing authenticated organization middleware and explicit permissions. A subscription belongs to the organization, not its creator's login session. At submission and approval application, its requester must hold the management permission and every source-read permission named by selected catalog entries; creation, scope expansion and enablement also require `webhook_payload:read`. Scopes are explicit event types, optionally narrowed by company IDs. An empty company list means organization-wide; a nonempty list matches only events with a listed company ID. This filter is not company-level RBAC, which the current application does not enforce.

Create subscriptions disabled. Creation, enablement, URL/event/company-scope changes, secret rotation and deletion use `ProposedChange` and existing approval policies. `webhook_subscription:update` exposes `name`, `url`, `eventTypes`, `companyIds`, `enabled`, and `rotateSecret`; gate these fields independently. Stale held changes fail rather than overwriting newer revisions. Emergency disable is immediate, audited and never approval-held; re-enabling follows the ordinary update policy. No webhook policy is installed automatically.

Each applied edit appends a revision. Deliveries pin the revision they matched. Before authorizing an attempt, check that the organization and subscription remain active, are not disabled, the current revision is enabled, the destination equals the pinned revision's, and current scopes still cover the event. Revocation cancels pending work; it never redirects it to a new URL. A request already authorized and in flight can complete after disable, and its timing remains evidence. Rotation and name-only changes do not cancel otherwise authorized deliveries. Losing the creator's membership does not implicitly revoke an approved organization integration.

Organization deletion cancels all pending tenant deliveries and emergency-disables subscriptions in the deleting transaction. Its `organization.deleted` event is retained but not sent; restoration does not re-enable integrations or revive canceled work.

Framework basis: existing [Vapor authentication/middleware](https://docs.vapor.codes/security/authentication/) and approval services; [Fluent soft delete](https://docs.vapor.codes/fluent/model/#soft-delete) preserves configuration history.

Rejected: tying deliveries to a former employee's current session; wildcard future-event subscriptions, which silently expand outbound authority; approval-gated emergency shutdown, which delays revocation.

### 5. Signed HTTPS with Standard Webhooks HMAC secrets

Sign with Standard Webhooks `v1` (HMAC-SHA256) because receiver libraries support it widely. Each subscription has one `whsec_`-prefixed secret of 32 random bytes. Sign `webhook-id.webhook-timestamp.raw-body` and send `webhook-id`, `webhook-timestamp` and `webhook-signature: v1,<base64>`; use the business event ID as `webhook-id` and put a distinct attempt UUID in `X-OpenERP-Attempt-ID`. Each attempt gets a fresh timestamp and uses the subscription's current secret. Document receiver timestamp validation and durable deduplication by event ID together with the receiver's own transaction.

A shared secret must be retrievable by the sender and disclosed to the customer, so:

- Generate a secret only when a subscription creation or `rotateSecret` applies; never place it in a proposed change.
- Encrypt it using AES-GCM and the deployment-provided base64 32-byte `WEBHOOK_KEY_ENCRYPTION_KEY`, binding organization, subscription and secret ID as associated data. Store ciphertext only in revision records; redact it from audit snapshots, DTOs and logs.
- Disclose it only through `POST /webhook-subscriptions/:id/secret`, which requires `webhook_secret:read` and appends a `webhook_secret_reveals` row in an audited transaction before returning the secret. Held creation or rotation can therefore be applied by an approver while the integrator retrieves the secret later under its own, recorded authority.
- Rotation is immediate: the new secret replaces the old one for all subsequent attempts. Graceful dual-signing is deferred.

Trade-off: unlike Ed25519 public keys, the platform holds a secret that can forge signatures, and disclosure needs its own control. That is accepted for receiver compatibility; the reveal ledger and immediate rotation are the compensating controls.

Require HTTPS on port 443, a valid hostname, no URL credentials, query, or fragment, and no redirects. Validate syntax on subscription writes and revalidate DNS destinations at each attempt. Block non-public IPv4/IPv6 addresses and cloud metadata ranges. The transport connects only to vetted addresses while retaining hostname TLS verification/SNI, using AsyncHTTPClient 1.36.2's documented `HTTPClient.Configuration.dnsOverride`. Use a bounded per-attempt client sharing event loops and shut it down after completion. This forgoes connection reuse (a TLS handshake per attempt); a short-lived client cache keyed by host and vetted address is a later optimization that must keep per-attempt revalidation. Declare the existing transitive package as a direct target dependency. A targeted TLS/transport test must verify the configuration before implementation is considered complete. Do not forward inbound authorization or cookies, or store response bodies/headers.

Framework/API basis: [Vapor client configuration](https://docs.vapor.codes/basics/client/#configuration), [AsyncHTTPClient API](https://swiftpackageindex.com/swift-server/async-http-client/documentation/asynchttpclient) and its [locked dnsOverride documentation](https://github.com/swift-server/async-http-client/blob/1.36.2/Sources/AsyncHTTPClient/HTTPClient.swift), [Swift Crypto](https://github.com/apple/swift-crypto) `HMAC<SHA256>` and `AES.GCM`, [Standard Webhooks](https://github.com/standard-webhooks/standard-webhooks/blob/main/spec/standard-webhooks.md), and [OWASP SSRF guidance](https://cheatsheetseries.owasp.org/cheatsheets/Server_Side_Request_Forgery_Prevention_Cheat_Sheet.html).

Rejected: Ed25519 `v1a`, which avoids a shared secret but has much narrower receiver-library support; custom cryptographic primitives; URL validation alone, which cannot prevent DNS rebinding.

### 6. Workers claim short leases and preserve ambiguous outcomes

Register `webhook-worker` as a Vapor `AsyncCommand`. It runs the dispatcher and sender loops, uses the same image/database as the API, no HTTP listener, no OIDC/JWKS startup, and a non-owner database role checked with the production runtime safety check. Compose defines separate `app` and `webhook-worker` services. Any number of worker replicas share all organizations. Use Swift cancellation and application shutdown to stop claiming work and finish/cancel bounded in-flight requests.

Claim due deliveries with `FOR UPDATE SKIP LOCKED`, assign a random lease token and 60-second lease, and append a started entry before network I/O. Recheck authority inside this short claim transaction. Make a single 10-second-deadline HTTP attempt outside it. Result updates require the same lease token; a late worker cannot overwrite a new owner's state. Recovery appends an `unknown` result for an expired started attempt before retrying. Never hold database locks across network I/O or mark work acknowledged before receiving a 2xx response.

Treat 2xx as `acknowledged`, not processed. Retry network failures, timeouts, 408, 425, 429 and 5xx; other statuses are terminal `exhausted`. Do not follow 3xx. Use full-jitter exponential delay starting at 5 seconds, capped at 6 hours, over a 72-hour window from the first authorized attempt. Honor a valid `Retry-After` for 429/503 without exceeding the window. Worker downtime before a first attempt does not consume the window. Cancellation of queued work appends a cancellation ledger entry with a bounded reason code.

In-flight limits are deployment configuration, enforced pool-wide by counting valid leases in Postgres:

| Variable | Default |
|---|---|
| `WEBHOOK_MAX_IN_FLIGHT` | 32 |
| `WEBHOOK_MAX_IN_FLIGHT_PER_ORGANIZATION` | 8 |
| `WEBHOOK_MAX_IN_FLIGHT_PER_SUBSCRIPTION` | 4 |
| `WEBHOOK_POLL_INTERVAL_MS` | 1000 |

Startup fails unless per-subscription ≤ per-organization ≤ global. Delivery promises no ordering, so per-subscription concurrency above 1 costs nothing semantically. Brief claim transactions take a worker-only advisory lock, lock the subscription, then claim its due delivery with `SKIP LOCKED`. Disable paths lock subscription before delivery as well, avoiding lock inversion with business transactions. Rotate organization selection to avoid starving other tenants and measure pending age. Pool throughput is roughly global limit ÷ endpoint latency; a load demo establishes the real ceiling before release.

Framework basis: [Vapor AsyncCommand](https://docs.vapor.codes/advanced/commands/#custom-commands), [Vapor environment](https://docs.vapor.codes/basics/environment/) for configuration, and [Postgres row/advisory locks](https://www.postgresql.org/docs/current/explicit-locking.html).

Rejected: in-process-only delivery, which couples capacity and failure domains to serving; per-process counters, which break when workers scale; fixed compiled-in limits, which cap throughput regardless of replicas.

### 7. Persistently failing endpoints are paused automatically

Each subscription tracks `failingSince`. When the sender records a `retryable`, `exhausted` or `unknown` result and `failingSince` is null, it sets it to that attempt's start time; an `acknowledged` result clears it. When a non-acknowledged result is recorded and `failingSince` is at least 72 hours old, the same transaction disables the subscription with reason `auto_paused`, system attribution `webhook-worker`, and cancels its queued deliveries with reason `subscription_auto_paused`. It logs a bounded warning. The rule requires continuous failure over the full retry window, so a single non-retryable 4xx or a slow trickle with occasional success does not pause an endpoint.

Auto-pause uses the same disabled state as emergency disable, distinguished by reason, so every authority check treats them identically. Re-enabling follows the ordinary approval-gateable update, which clears `failingSince`. Health exposes `failingSince` and the disabled reason. The subscription is audited, so transitions are evidence; `failingSince` changes only on transitions, not on every attempt.

Rejected: leaving exhausted work to accumulate behind a health flag, which wastes pool capacity on dead endpoints; pausing after a fixed count of failures, which punishes high-volume subscribers for a brief outage.

### 8. History and health are public API capabilities

Use paginated catalog, subscription/revision, event and delivery/attempt routes with the exact permission/filter/order contracts in the specs. Expose backlog age, counts by state, most recent acknowledgment/failure, `failingSince` and disabled reason for integration health; sensitive event bodies require `webhook_payload:read` in addition to metadata permissions. Audit snapshots redact event payload bytes and secret ciphertext but retain IDs, digest, type, scopes and attribution. Evidence is retained indefinitely.

Framework basis: existing list contract and [Fluent pagination](https://docs.vapor.codes/fluent/query/#pagination); [Vapor routing](https://docs.vapor.codes/basics/routing/).

## Deferred Scope

Each item below is valuable but separable, and is left to a follow-up change so this one stays reviewable:

- Approval-gated replay of terminal deliveries.
- Synthetic `webhook.test` deliveries.
- `GET /webhook-events/:id/evidence` cross-table evidence aggregation.
- `webhook-verify` coverage reconciliation of audit transactions against events, events against deliveries, and abandoned attempts.
- Graceful secret rotation with dual signatures.
- Partitioning/archival of terminal deliveries and HTTP client reuse.

## Risks / Trade-offs

- Explicit emitters can be missed → catalog-to-operation tests now; audit reconciliation via the deferred `webhook-verify`; audit triggers remain independent evidence.
- Fan-out happens after commit → a subscription disabled between event and dispatch receives nothing, which matches revocation intent; dispatch lag adds up to one poll interval of latency.
- Unaudited dispatch queue → a privileged actor could delete a dispatch row and suppress delivery; the event itself remains audited and the deferred reconciliation detects events without expected deliveries.
- Endpoint accepts then worker crashes → retry can duplicate; stable event identity, append-only unknown outcomes and receiver idempotency are contractual.
- Shared HMAC secret → platform-held secret could forge signatures if leaked; encrypted at rest, disclosure recorded, rotation immediate.
- Revocation races an already authorized send → document the in-flight boundary and retain authorization/start/result timestamps; queued work stops.
- Strict outbound networking needs more than the generic client API → require a tested vetted-address transport and blocked-address/rebinding demos before release.
- New permission catalog changes who qualifies as a full administrator → fresh pre-release databases receive revised templates.

## Migration Plan

1. Add one create migration per new table, following the repository pre-release policy. Edit existing create migrations in place where table definitions, trigger events or redaction arguments must change; do not add alter chains. The app is unreleased, so existing databases are reset rather than bootstrapped.
2. Provision the webhook encryption key through deployment secret injection and back it up with the database recovery procedure; never commit a production key.
3. Deploy migrations and the event-producing application version, then start API and worker processes with no active subscriptions. Validate runtime role checks, a crash/retry demo and a throughput demo, then enable subscriptions under configured approvals.
4. Roll back by stopping workers first. Preserve evidence and pending work; correct schema/code forward.

## Open Questions

No product decisions block implementation. Production retention periods, archive infrastructure and customer delivery targets require separate decisions before being advertised.
