## ADDED Requirements

### Requirement: Organization subscription management
The system SHALL expose `POST /webhook-subscriptions`, `GET /webhook-subscriptions`, `GET /webhook-subscriptions/:id`, `PATCH /webhook-subscriptions/:id`, `DELETE /webhook-subscriptions/:id` and `GET /webhook-subscriptions/:id/versions`. Create/read/update/delete SHALL require their matching `webhook_subscription` permission; versions SHALL require read. All routes SHALL require authentication, `X-Organization-ID` and active membership. Cross-tenant item IDs SHALL return `404`; a non-member organization SHALL return `403` without revealing its existence.

A subscription SHALL have a name of 1–100 characters, a safe HTTPS URL, a nonempty explicit set of catalog event types, an explicit company-ID set, and enabled state. It SHALL be created disabled, with no wildcard event types. An empty company set SHALL mean organization-wide; a nonempty set SHALL match only events whose non-null `companyId` belongs to that set. Supplied company IDs SHALL belong to active companies in that organization. Selecting a type that has no company context together with a nonempty company filter SHALL return `400`. At most 100 non-deleted subscriptions SHALL exist per organization; concurrent creates SHALL not exceed the limit. Creation, scope expansion and enablement SHALL require `webhook_payload:read` and the requester's source-read permissions for every selected event at submission and again when applying a held change. Organization authority SHALL remain valid independently of the creator's subsequent session or membership.

#### Scenario: Disabled creation
- **WHEN** an authorized administrator creates a valid subscription
- **THEN** its applied configuration is disabled and no business payload is sent until an authorized enablement applies

#### Scenario: Company filter narrows delivery
- **WHEN** a subscription selects company events and company A in its organization
- **THEN** only events for company A match, and an organization-level event cannot bypass the filter

#### Scenario: Cross-tenant scope rejected
- **WHEN** a subscription references another organization's company or subscription
- **THEN** a company reference is rejected without data disclosure and an item reference returns `404`

#### Scenario: Required authority missing
- **WHEN** a member lacks management, payload, or a selected source-read permission required by the operation
- **THEN** submission is rejected with `403` and no subscription change is applied

### Requirement: Immutable approved configuration revisions
Every applied subscription create/update SHALL append an immutable revision containing its configuration including enabled state, outbound scopes, secret ID and encrypted signing secret, creator, nullable approval request ID and a database-transaction `createdAt`. The subscription SHALL reference its current revision. Configuration changes SHALL use existing approval submission/application behavior; a held change SHALL not change current configuration or outbound authority. Changes SHALL check the expected current revision both when submitted and applied; stale application SHALL fail without overwriting later edits. Ordinary deletion SHALL be soft deletion and approval-gateable. Secrets SHALL be generated only on actual application, never stored in proposed changes. Revision records SHALL reject update/delete/truncate, and APIs other than secret disclosure SHALL never return a secret or its ciphertext.

#### Scenario: Held activation
- **WHEN** an enablement matches an approval policy
- **THEN** the API returns `202`, the current revision remains disabled and delivery cannot begin until successful application

#### Scenario: Stale held URL change
- **WHEN** a URL change is held and another configuration revision applies first
- **THEN** final approval marks the held operation failed and preserves the newer configuration

#### Scenario: Source authority revoked before approval
- **WHEN** the requester loses a required source-read permission before a held scope expansion applies
- **THEN** application fails and no outbound scope expands

### Requirement: Pinned payload schema
Every subscription revision in this release SHALL pin the public payload schema version to 1 and expose that version in metadata. Adding a future incompatible payload version SHALL not silently upgrade existing subscriptions; an explicit subscription upgrade and separately specified compatibility path SHALL be required.

#### Scenario: Payload version remains pinned
- **WHEN** a subscription revision is created or edited in this release
- **THEN** its public payload schema version is 1 and metadata advertises that fixed contract

### Requirement: Emergency revocation and organization lifecycle
`POST /webhook-subscriptions/:id/disable` SHALL require `webhook_subscription:disable`, immediately set disabled state with reason `emergency` and the actor's attribution in an audited transaction, and SHALL NOT be approval-held. The worker MAY set disabled state with reason `auto_paused` as defined by webhook-delivery. Re-enabling from either reason SHALL require an ordinary approved update. Before authorizing each delivery attempt the worker SHALL check active organization/subscription, that the subscription is not disabled, that its current revision is enabled, that the destination equals the pinned revision's, and current event/company scopes. It SHALL cancel unauthorized queued work, not redirect it or silently revive it later. A request authorized before revocation MAY already be in flight; its original attempt timing and outcome SHALL remain evidence.

Organization deletion SHALL disable every subscription with reason `emergency` and cancel queued tenant deliveries in that transaction. Its deletion event SHALL be retained but not sent. Restoration SHALL not automatically re-enable subscriptions, redeliver canceled events or restore child resources. Name-only changes and secret rotations SHALL not invalidate otherwise-authorized work.

#### Scenario: Emergency disable bypasses approval hold
- **WHEN** an authorized operator disables a subscription even though updates require approval
- **THEN** no new attempt can be authorized after disable commits and pending work becomes cancelled

#### Scenario: Revocation during an in-flight request
- **WHEN** a request was authorized before disable and completes afterward
- **THEN** its outcome is retained and the worker does not schedule another attempt

#### Scenario: Organization restored
- **WHEN** a deleted organization is restored
- **THEN** its restore event is recorded and integrations remain disabled until explicit re-enablement

#### Scenario: Unauthorized emergency disable
- **WHEN** a member lacks `webhook_subscription:disable`
- **THEN** disable returns `403` and changes nothing

### Requirement: Safe destinations and signing keys
Subscription URLs SHALL use HTTPS on port 443 with a hostname and no user information, query or fragment. The system SHALL reject unsafe syntax with `400`, disallow redirects, verify TLS hostname/certificates, and block all non-public IPv4/IPv6 and metadata destinations on every attempt. Connection establishment SHALL use the vetted destination addresses without a second unchecked resolution, while preserving hostname verification. Unsafe resolutions SHALL cancel the delivery without a network request to the blocked destination. Inbound credentials/cookies SHALL never be forwarded.

The system SHALL generate a unique Standard Webhooks secret per subscription, consisting of the `whsec_` prefix and 32 random bytes in base64, when a creation or `rotateSecret: true` update applies. It SHALL store the secret only encrypted with authenticated organization/subscription/secret-ID binding. Rotation SHALL be immediate: subsequent attempts SHALL sign only with the new secret. Rotation SHALL be approval-gateable through the update route. API responses other than secret disclosure, proposed changes, audit snapshots, errors and logs SHALL never reveal a secret or its ciphertext.

#### Scenario: Redirect cannot reach internal service
- **WHEN** an endpoint responds with a redirect to an internal address
- **THEN** the worker records a terminal response without following it

#### Scenario: DNS rebinding blocked
- **WHEN** a hostname's address changes between validation and connection
- **THEN** the transport connects only to its vetted public addresses or fails safely, never using a new unchecked private address

#### Scenario: Immediate rotation
- **WHEN** a held `rotateSecret` update is approved and applies
- **THEN** a new revision records a new secret ID, attempts authorized afterward sign only with the new secret, and no response or audit row contains either secret

### Requirement: Recorded secret disclosure
`POST /webhook-subscriptions/:id/secret` SHALL require `webhook_secret:read`, authentication, active membership and `X-Organization-ID`, and SHALL return the subscription's current secret and secret ID. Before returning, it SHALL append a `webhook_secret_reveals` record containing organization, subscription, secret ID, actor and request ID in an audited transaction; if the record cannot be written, no secret SHALL be returned. Reveal records SHALL reject update/delete/truncate. Responses SHALL set `Cache-Control: no-store`. Cross-tenant or deleted subscriptions SHALL return `404`. Holding subscription management permissions SHALL not imply `webhook_secret:read`.

#### Scenario: Integrator retrieves secret after approval
- **WHEN** a held creation is applied by an approver and an integrator with `webhook_secret:read` then requests the secret
- **THEN** the secret is returned and a reveal record attributes the disclosure to the integrator

#### Scenario: Secret permission missing
- **WHEN** a member with `webhook_subscription:update` but without `webhook_secret:read` requests the secret
- **THEN** the system responds `403` and records no disclosure

### Requirement: Subscription collection contracts
Subscription and revision lists SHALL follow list-endpoints. `GET /webhook-subscriptions` SHALL order by subscription `updatedAt` descending then `id` ascending, accept text filter `name`, exact filters `enabled` and `eventType`, and no sort parameter. Subscriptions disabled for any reason SHALL count as disabled. `GET /webhook-subscriptions/:id/versions` SHALL order by revision `createdAt` descending then `id` ascending with no filters or sort parameter. Metadata SHALL include current configuration, disabled reason and attribution, `failingSince`, current revision and current secret ID but no payloads or secrets. New catalog permissions SHALL not by themselves broaden existing organization-owned subscriptions.

#### Scenario: Strict subscription filters
- **WHEN** an authorized member supplies an unknown/repeated filter, invalid boolean or unknown event type
- **THEN** the list responds `400` naming the parameter

#### Scenario: Revision tenant isolation
- **WHEN** an organization A member requests versions for organization B's subscription
- **THEN** the system responds `404` and no revision is exposed
