## ADDED Requirements

### Requirement: Durable dispatch and deliveries
Event capture SHALL save one dispatch record per event atomically with the event, without reading subscriptions or creating deliveries in the business transaction. The worker dispatcher SHALL claim dispatch records with `SKIP LOCKED` and, in one transaction, create deliveries and delete the dispatch record. For each non-deleted, not-disabled subscription in the event's organization, it SHALL select the highest configuration version visible in the event's captured database snapshot and create one delivery pinned to that revision only if the revision is enabled and its scopes cover the event. `occurredAt` and revision `createdAt` SHALL use the database transaction timestamp for evidence, not eligibility. The event SHALL retain its capture snapshot, and revisions SHALL retain their top-level transaction ID and a monotonic configuration version allocated under the subscription lock. Eligibility SHALL require that the revision transaction was committed before the event snapshot, or belongs to the same transaction and has an earlier internal capture order. Snapshot and ordering metadata SHALL not be public. Delivery uniqueness on organization, event and subscription SHALL be enforced in the database, so re-dispatch is idempotent. All event, revision, dispatch, delivery and ledger references SHALL enforce same-organization ownership. No worker SHALL consume uncommitted work. Pending work SHALL survive API/worker restart, and a stopped worker SHALL not make otherwise-valid business writes fail.

#### Scenario: Worker offline
- **WHEN** an API operation commits while no worker is running
- **THEN** the API succeeds, its dispatch record remains durable and a restarted worker creates and sends its deliveries

#### Scenario: No retrospective delivery
- **WHEN** a subscription is enabled, or its scope widened, after an event occurred
- **THEN** dispatch does not create a delivery for that event to that subscription

#### Scenario: Enablement transaction started before the event but committed afterward
- **WHEN** an enablement transaction starts, an event is captured and commits while enablement remains uncommitted, and enablement then commits before dispatch
- **THEN** its earlier transaction timestamp does not make that revision eligible for the event

#### Scenario: Configuration timestamps decrease under contention
- **WHEN** an early-started edit waits for a later-started edit to commit and then applies a higher configuration version
- **THEN** events captured afterward use the highest visible configuration version, regardless of timestamp order

#### Scenario: Disabled before dispatch
- **WHEN** a subscription is disabled after an event commits but before it is dispatched
- **THEN** no delivery is created for that subscription

#### Scenario: Dispatch re-run
- **WHEN** a dispatcher crashes after inserting deliveries but before commit and the record is claimed again
- **THEN** each matching subscription has exactly one delivery for the event

#### Scenario: Tenant reference constraint
- **WHEN** a delivery references another organization's event or subscription revision
- **THEN** the database rejects the write

### Requirement: Separate bounded delivery worker
`webhook-worker` SHALL continuously claim due deliveries using short database transactions, expiring leases and owner tokens. It SHALL append an attempt-start entry before HTTP I/O, send outside database transactions and update mutable scheduling state only while holding the same lease token. The HTTP deadline SHALL be 10 seconds and the lease 60 seconds. Recovery SHALL append an unknown result for an expired started attempt before retrying; a stale worker SHALL not overwrite a replacement owner's result. A request SHALL not be marked acknowledged before a received 2xx response. Shutdown SHALL stop claiming and bound in-flight completion/cancellation.

Each worker process SHALL bound its own in-flight attempts by its configured concurrency, so pool capacity grows with replicas. The per-subscription in-flight limit SHALL be exact across all processes, enforced by counting unexpired leases while holding the subscription row lock taken by the claim. The per-organization limit SHALL be enforced across processes by counting unexpired leases without an organization-wide lock and MAY be exceeded briefly by concurrent claims. Claims SHALL not take a pool-wide lock. Leases SHALL release capacity on completion/expiry. Unhealthy subscriptions SHALL not monopolize claims or starve another organization with due work. Workers SHALL not require one process per organization. Claim and dispatch queries SHALL use partial indexes over unfinished work so their cost does not grow with retained history.

#### Scenario: Two workers compete
- **WHEN** two workers claim the same due delivery concurrently
- **THEN** only one valid lease authorizes its attempt

#### Scenario: Crash after remote acceptance
- **WHEN** the endpoint accepts a webhook and the worker crashes before persisting the response
- **THEN** the abandoned attempt becomes unknown and the same event can be delivered again after recovery

#### Scenario: Late worker is fenced
- **WHEN** an expired worker completes after a new owner claims the delivery
- **THEN** its stale token cannot change the new owner's scheduling state or terminal result

#### Scenario: Subscription limit survives scaling
- **WHEN** several worker processes claim work for one subscription concurrently
- **THEN** its in-flight attempts never exceed the per-subscription limit

#### Scenario: Unhealthy endpoint isolated
- **WHEN** one organization's endpoint is unavailable and another organization has due work
- **THEN** the other organization's deliveries proceed

#### Scenario: Capacity grows with replicas
- **WHEN** a second worker process starts against a backlog across many subscriptions
- **THEN** total in-flight attempts can exceed one process's concurrency

### Requirement: Signed stable delivery bodies
Business notifications SHALL use POST with the exact retained JSON bytes and Standard Webhooks `v1` HMAC-SHA256 signatures: `webhook-id` equal to event ID, a fresh Unix-seconds `webhook-timestamp`, `webhook-signature` of the form `v1,<base64>`, and a distinct `X-OpenERP-Attempt-ID`. The signature input SHALL be `webhook-id.webhook-timestamp.raw-body`, keyed by the subscription's current secret at attempt time. Automatic retries SHALL preserve event identity and body bytes, while timestamps, attempt IDs and the current secret can change. Documentation SHALL instruct receivers to verify the signature and timestamp freshness and deduplicate event IDs atomically with business effects for the retry horizon. Delivery SHALL make no ordering or exactly-once external-processing guarantee.

#### Scenario: Verify exact bytes
- **WHEN** a receiver verifies a notification using a Standard Webhooks library, its subscription secret and the raw body
- **THEN** the signature validates, and changing a byte causes verification to fail

#### Scenario: Retry identity stable
- **WHEN** a delivery is retried
- **THEN** its event ID and body are unchanged and its attempt ID is new

### Requirement: Retry policy and visible terminal outcomes
Delivery states SHALL be `pending`, `in_flight`, `retrying`, `acknowledged`, `exhausted` or `cancelled`. A 2xx response SHALL acknowledge transport receipt only. Network failures, timeouts, 408, 425, 429 and 5xx SHALL be retryable using full-jitter exponential delay starting at 5 seconds and capped at 6 hours, within 72 hours of the first authorized attempt. A valid `Retry-After` on 429/503 SHALL be honored without exceeding that window. Other HTTP statuses SHALL exhaust delivery without an automatic retry; redirects SHALL not be followed. Authorization/safety revocations SHALL cancel delivery. Worker downtime before a first attempt SHALL not consume the retry window. Exhaustion/cancellation SHALL retain bounded reason codes and history, and no retry SHALL erase an earlier result.

#### Scenario: Temporary throttling
- **WHEN** an endpoint responds `429` with a valid retry delay inside the window
- **THEN** the worker records the attempt and schedules a later retry respecting that delay

#### Scenario: Window exhausted
- **WHEN** repeated failures reach the 72-hour deadline
- **THEN** the delivery becomes exhausted, remains queryable and receives no automatic attempt

#### Scenario: Acknowledgment is not business completion
- **WHEN** an endpoint returns `202`
- **THEN** delivery is acknowledged without recording that downstream financial processing completed

### Requirement: Automatic pause of failing subscriptions
Each subscription SHALL track `failingSince`. Recording a `retryable`, `exhausted` or `unknown` result SHALL set it to that attempt's start time when null; recording an `acknowledged` result SHALL clear it. When a non-acknowledged result is recorded and `failingSince` is at least 72 hours before the result time, the worker SHALL, in that transaction, disable the subscription with reason `auto_paused` and system attribution naming `webhook-worker`, and cancel its queued deliveries with reason `subscription_auto_paused`. It SHALL log a bounded warning without payloads or secrets. Auto-paused subscriptions SHALL be treated as disabled by every authorization check. Re-enabling SHALL require an ordinary update to `enabled`, subject to approval policy, and SHALL clear `failingSince`.

#### Scenario: Endpoint down for the full window
- **WHEN** a subscription has recorded no acknowledgment for 72 hours and another attempt fails
- **THEN** it becomes disabled with reason `auto_paused`, its queued deliveries are cancelled and no further attempt is authorized

#### Scenario: Single terminal rejection
- **WHEN** a healthy subscription's endpoint returns `400` once
- **THEN** that delivery is exhausted and the subscription is not paused

#### Scenario: Intermittent success
- **WHEN** an endpoint fails most attempts but acknowledges one within each 72-hour period
- **THEN** `failingSince` is cleared on each acknowledgment and the subscription is not paused

#### Scenario: Re-enable after pause
- **WHEN** an authorized update sets `enabled` on an auto-paused subscription and applies
- **THEN** the subscription is enabled, `failingSince` is cleared and only events occurring after that revision are dispatched to it

### Requirement: Append-only delivery evidence
Each attempt SHALL have an immutable started ledger entry and at most one immutable result entry, with attempt ID, delivery, organization, pinned subscription revision, secret ID, payload digest, authorization/start time, finish time, HTTP status if received, and bounded outcome/error category. Cancelling a queued delivery SHALL append a cancellation entry with a bounded reason code. Recovery SHALL preserve unknown outcomes. Entries SHALL reject updates, deletes and truncation. The ledger SHALL exclude secrets, request credentials, response bodies, raw network exception text and arbitrary response headers. Delivery scheduling state SHALL be reconstructable from the delivery's creation and its ledger entries. Worker writes SHALL carry system audit attribution naming the command. Event/configuration/evidence history SHALL be retained indefinitely, with no purge command in this change.

#### Scenario: Ambiguous attempt retained
- **WHEN** a started attempt has no persisted response after lease expiry
- **THEN** recovery appends unknown and neither fabricates acknowledgment nor removes its start evidence

#### Scenario: Cancellation recorded
- **WHEN** emergency disable cancels a delivery that was never attempted
- **THEN** a cancellation entry with its reason exists for that delivery

#### Scenario: Evidence tampering rejected
- **WHEN** the runtime role updates or deletes a ledger entry, event or configuration revision
- **THEN** the database rejects the mutation

### Requirement: Delivery history and health APIs
`GET /webhook-deliveries`, `GET /webhook-deliveries/:id`, `GET /webhook-deliveries/:id/attempts` and `GET /webhook-subscriptions/:id/health` SHALL require `webhook_delivery:read`, authentication, active membership and `X-Organization-ID`. Item references in another organization SHALL return `404`. Lists SHALL follow list-endpoints, with `createdAt` descending and `id` ascending, no sort parameter, and the following filters:

| Endpoint | Exact filters | Time filters |
|---|---|---|
| `/webhook-deliveries` | `subscriptionId`, `eventId`, `state` | Inclusive `from`, `to` on delivery `createdAt` |
| `/webhook-deliveries/:id/attempts` | `outcome` (`started`, `acknowledged`, `retryable`, `exhausted`, `unknown`) | Inclusive `from`, `to` on start `createdAt` |

Attempts SHALL be logical start/result pairs identified by attempt ID, ordered by their immutable start timestamp; an unfinished pair SHALL show started. Delivery metadata SHALL include its cancellation reason when cancelled. Metadata SHALL omit business bodies and sensitive values. Health SHALL be a single resource containing counts by state, oldest queued timestamp, last acknowledgment/failure timestamps, median attempt duration over the last 24 hours, `failingSince`, disabled reason and `needsAttention`; it SHALL flag queued work older than five minutes, an exhausted delivery since the last acknowledgment, or an auto-paused subscription. Logs SHALL emit bounded warnings for exhaustion, auto-pause, unsafe destinations and excessive queue or dispatch age without exposing payloads/credentials. Each worker SHALL log a summary every 60 seconds with its in-flight count, oldest undispatched event age, oldest due delivery age and median/maximum claim-transaction duration. `GET /webhook-deliveries/:id/payload` SHALL additionally require `webhook_payload:read` and the event's source-read permission.

#### Scenario: Delivery tenant isolation
- **WHEN** an organization A member filters deliveries by organization B's event
- **THEN** it returns an empty page and zero total, and direct access to B's attempt history returns `404`

#### Scenario: Missing delivery permission
- **WHEN** a member without `webhook_delivery:read` lists deliveries or health
- **THEN** the system responds `403`

#### Scenario: Payload remains restricted
- **WHEN** a member can inspect delivery metadata but lacks `webhook_payload:read`
- **THEN** payload inspection responds `403` and metadata does not expose the body

#### Scenario: Auto-pause visible
- **WHEN** an authorized member reads health for an auto-paused subscription
- **THEN** it reports disabled reason `auto_paused`, its `failingSince` and `needsAttention` true
