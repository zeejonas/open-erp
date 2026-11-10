## ADDED Requirements

### Requirement: Service account registration
A member with `service_account:create` SHALL be able to register a service account with `POST /service-accounts`, supplying a `name`, an optional `description`, an optional `ownerId`, and the `subject` that the identity provider's client-credentials tokens carry. The system SHALL create a user of kind `service` bound to that subject, an active membership in the caller's organization, and a service account record. The new account SHALL belong to no group. The `subject` SHALL be unique across all users, and a subject already bound responds `409 Conflict` without revealing which organization or user holds it. The system SHALL NOT issue, store or display any credential secret.

#### Scenario: Register an integration
- **WHEN** a member with `service_account:create` registers "AP integration" with subject `abc@clients`
- **THEN** the system responds `200` with the account, which is enabled, has no groups, and has never been used

#### Scenario: Subject already bound
- **WHEN** a member registers a subject that is already bound to a person or another service account in any organization
- **THEN** the system responds `409 Conflict` and nothing is created

#### Scenario: Missing permission
- **WHEN** a member without `service_account:create` calls `POST /service-accounts`
- **THEN** the system responds `403 Forbidden`

### Requirement: Service account owner
Every service account SHALL have an owner, a person who is an active member of the account's organization. The owner SHALL default to the caller. An `ownerId` that is not an active person member of the organization, including a service account or a member of another organization, SHALL respond `400 Bad Request`. Ownership SHALL be recorded for accountability and SHALL NOT grant any permission.

#### Scenario: Default owner
- **WHEN** a member registers a service account without `ownerId`
- **THEN** the caller is the owner

#### Scenario: Service account as owner
- **WHEN** a member sets `ownerId` to a service account
- **THEN** the system responds `400` and nothing changes

#### Scenario: Owner from another organization
- **WHEN** a member of organization A sets `ownerId` to a user who belongs only to organization B
- **THEN** the system responds `400` and nothing changes

### Requirement: Service account listing
A member with `service_account:read` SHALL be able to list the organization's non-deleted service accounts with `GET /service-accounts` and view one with `GET /service-accounts/:id`. Each account SHALL include its id, name, description, owner id, bound subject, enabled state, disabled time and actor, last-used time, and created and updated times and actors. The list SHALL follow the list-endpoints capability, SHALL declare the filters `name` (case-insensitive contains), `enabled`, and `ownerId`, and SHALL order by `createdAt`. An account in another organization SHALL respond `404 Not Found`.

#### Scenario: Access review
- **WHEN** a member with `service_account:read` calls `GET /service-accounts?enabled=true`
- **THEN** the response lists each enabled account of the organization with its owner and last-used time

#### Scenario: Tenant isolation
- **WHEN** a member of organization A calls `GET /service-accounts/:id` for an account of organization B
- **THEN** the system responds `404 Not Found`

#### Scenario: Missing permission
- **WHEN** a member without `service_account:read` calls `GET /service-accounts`
- **THEN** the system responds `403 Forbidden`

### Requirement: Service account updates
A member with `service_account:update` SHALL be able to change `name`, `description`, `ownerId`, `subject`, and `enabled` with `PATCH /service-accounts/:id`. Setting `enabled` to `true` SHALL re-enable a disabled account. Changing `subject` SHALL bind the account to a different identity provider client, and tokens for the previous subject SHALL stop resolving to it. The subject uniqueness rule and owner rule SHALL apply.

#### Scenario: Replace the client
- **WHEN** a member changes an account's `subject` from `old@clients` to `new@clients`
- **THEN** tokens with subject `new@clients` act as the account and tokens with `old@clients` are refused with `403`

#### Scenario: Re-enable
- **WHEN** a member sets `enabled` to `true` on a disabled account
- **THEN** the account's tokens are accepted again

#### Scenario: Another organization's account
- **WHEN** a member of organization A patches an account of organization B
- **THEN** the system responds `404 Not Found`

### Requirement: Immediate disable
A member with `service_account:disable` SHALL be able to disable a service account with `POST /service-accounts/:id/disable`. Disabling SHALL take effect immediately, SHALL record the disabling actor and time, SHALL NOT be held for approval, and SHALL be idempotent. Requests already authorized MAY finish.

#### Scenario: Emergency shutdown
- **WHEN** a member disables an account while its access token is unexpired
- **THEN** the account's next request is refused with `403`

#### Scenario: Disable is never held
- **WHEN** an approval policy covers `service_account:update` and a member disables an account
- **THEN** the system responds `204` and the account is disabled without an approval request

### Requirement: Service account deletion
A member with `service_account:delete` SHALL be able to delete a service account with `DELETE /service-accounts/:id`. Deletion SHALL soft-delete the account, its user, its organization membership, and its group memberships, recording `deleted_by` on each, and SHALL release its subject so that it can be registered again. Records the account created or changed SHALL keep their attribution.

#### Scenario: Delete
- **WHEN** a member deletes an account
- **THEN** its tokens are refused with `403`, it is absent from `GET /service-accounts`, and records it created still name it in `created_by`

#### Scenario: Subject reusable
- **WHEN** an account bound to `abc@clients` is deleted and a member registers a new account with `abc@clients`
- **THEN** the registration succeeds

### Requirement: Last-used evidence
The system SHALL record when a service account last authenticated successfully, updating the stored time at most once per 24 hours per account, so that concurrent requests write at most once. Each update SHALL be audited with the service account as actor. A failure to record last use SHALL NOT fail the request.

#### Scenario: First use
- **WHEN** a never-used account makes an authenticated request
- **THEN** its last-used time is set and one audit event records the change

#### Scenario: Repeated use
- **WHEN** the account makes 100 requests within an hour of its last recorded use
- **THEN** its last-used time and audit events are unchanged
