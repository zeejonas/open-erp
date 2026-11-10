## Context

Today every authenticated caller is a person. The request pipeline works like this:

1. `verifiedAccessToken()` checks the signature, `iss`, `aud`, `exp` and revocation, without caring who the subject is.
2. `AuthMiddleware` resolves the `sub` to `users.auth_subject`.
3. `OrganizationMiddleware` requires an active `organization_users` row.
4. `loadPermissions` walks memberships, groups and roles.
5. `auditedTransaction` records the caller as actor.

Forty-eight `created_by` / `updated_by` / `deleted_by` foreign keys across 17 tables reference `users(id)`, and so do the approval requester and `audit_events.actor_id`.

The server does not control identity, because tokens come from the configured OIDC provider. Supported providers issue client-credentials access tokens from the same issuer and JWKS as user tokens, so verification needs no changes.

## Goals / Non-Goals

**Goals:**
- A non-human principal that authenticates with IdP client-credentials tokens.
- The principal belongs to one organization and gets permissions through existing groups and roles.
- Writes are attributed as `service_account`.
- Lifecycle changes are audited and approval-gateable, with immediate disable.
- Evidence for access reviews: owner, enabled state and last use.

**Non-Goals:** see proposal.md. These include app-issued keys, IdP management APIs, server-enforced grant limits, seats, and proof of client ownership.

## Decisions

### 1. A service account is a `users` row with `kind = service`, plus a 1:1 `service_accounts` row

`users` gains `kind` (`person` | `service`, default `person`). `service_accounts` shares its primary key with `users.id`. It holds:
- `organization_id`
- `owner_id`, which references a person user
- `description`
- `disabled_at`, `disabled_by`
- `last_used_at`
- the standard attribution and timestamp columns

Each account also has an ordinary `organization_users` row, so the existing pieces work unchanged:
- `OrganizationMiddleware`
- group membership and `loadPermissions`
- approval requester and withdrawal
- every `*_by` foreign key

Service rows keep the existing required `users` columns:
- `first_name` holds the account name.
- `last_name` is empty.
- `email` is `<id>@service-accounts.invalid`. The `.invalid` TLD is reserved by [RFC 2606 §2](https://www.rfc-editor.org/rfc/rfc2606#section-2) and can never be a verified IdP email, so no invitation can ever match it.

Two rules protect the data:
- A `CHECK` constraint, `kind = 'person' OR NOT is_platform_admin`, keeps service accounts out of platform administration.
- The owner must be a person who is an active member. The application enforces this when the write is submitted and again when it is applied.

The app generates the ID so the email can be derived in the same insert. Fluent supports app-generated IDs with `@ID(custom:generatedBy: .user)`, as described in [Fluent models: identifier](https://docs.vapor.codes/fluent/model/#identifier).

Rejected alternatives:
- A standalone `service_accounts` principal table: every `*_by` foreign key and the approval requester would have to become polymorphic.
- Nullable `first_name`, `last_name` and `email`: about 55 person-only call sites would have to change for no behavioral gain.

### 2. Credentials: register the IdP client's token subject

An org admin creates a client-credentials client in the IdP for the configured audience, then registers the subject its tokens carry. `POST /service-accounts` stores that subject in `users.auth_subject`. The column is unique and is excluded from audit values.

`AccessToken` and `verifiedAccessToken()` stay unchanged. The token is verified with the same `app.jwt.keys` collection ([Vapor JWT](https://docs.vapor.codes/security/jwt/)). Userinfo is never called for service accounts.

Rotation means rotating the client secret in the IdP. Moving to a new client is a gateable `PATCH` of `subject`.

The subject format depends on the provider. The docs task records each one after checking it against the provider's documentation. Expected formats:
- Auth0: `<client_id>@clients`
- Okta: the client id
- Entra ID: the service principal object id

Rejected alternatives:
- App-issued hashed API keys: a second authentication path with long-lived secrets.
- Provider management APIs: provider-specific coupling.
- An app token endpoint: makes the app an authorization server with its own signing keys.

### 3. `AuthMiddleware` enforces disable and records last use

After `User.bound`, when `kind == .service`, the middleware loads the `ServiceAccount`. A missing, deleted or disabled account gets `403`, the same as an unknown subject.

This per-request database check makes disable and delete take effect immediately while tokens are still valid. It is the same reason revocation uses the shared database ([Vapor middleware](https://docs.vapor.codes/advanced/middleware/)).

When `last_used_at` is null or more than 24 hours old, the middleware updates it. The update is a single SQLKit conditional statement inside `auditedTransaction`, attributed to the service account:

```sql
UPDATE service_accounts SET last_used_at = now()
WHERE id = $1 AND (last_used_at IS NULL OR last_used_at < now() - interval '1 day')
```

Concurrent requests therefore write at most once, and the audit trail gains at most one event per account per day ([SQLKit raw queries](https://docs.vapor.codes/fluent/advanced/#raw-sql), [Fluent transactions](https://docs.vapor.codes/fluent/transaction/)).

A failure is logged and does not fail the request. Last use is review evidence, not an authorization input.

Rejected alternatives:
- Updating on every request: write amplification and audit noise.
- An unaudited usage side table: would need an exception to audit coverage.

### 4. Attribution comes from `kind`

`AuditActorType` gains `serviceAccount = "service_account"`. `Request.auditContext()` uses it when the resolved user's kind is `service`, keeping `actor_id` as the account ID. Business events get the same value because they reuse `AuditActorType`.

The account's own audit history (its `users`, `service_accounts`, `organization_users` and `group_members` rows) shows who created and changed it.

### 5. Routes and approval gating mirror webhook subscriptions

| Route | Permission | Gating |
|---|---|---|
| `POST /service-accounts` | `service_account:create` | gateable |
| `GET /service-accounts`, `GET /service-accounts/:id` | `service_account:read` | none |
| `PATCH /service-accounts/:id` (`name`, `description`, `ownerId`, `subject`, `enabled`) | `service_account:update` | gateable |
| `POST /service-accounts/:id/disable` | `service_account:disable` | never held |
| `DELETE /service-accounts/:id` | `service_account:delete` | gateable |

Each held write becomes a `ProposedChange` case, applied through the existing `ApprovalService`.

Creating an account does not add it to any group. Admins grant access with the existing group-member routes, which have their own gating.

Delete soft-deletes these rows:
- the `service_accounts` row
- the `users` row
- the `organization_users` row
- the account's group memberships

It also clears `auth_subject`, so the client can be registered again later.

`GET /service-accounts` follows list-endpoints:
- filters: `name` (contains), `enabled`, `ownerId`
- order timestamp: `createdAt`, because `last_used_at` updates must not reorder pages

Rejected: disabling only through `PATCH`, because emergency shutdown must not wait for approval.

### 6. Person-only surfaces

These surfaces reject service accounts or leave them out:
- `GET /me` and `PATCH /me` respond `403` to a service account.
- Invitation acceptance responds `403` to a service-bound subject.
- `GET /users` and `GET /users/:id` return people only.
- `DELETE /organization-users/:userID` responds `404` for a service account; use `DELETE /service-accounts/:id` instead.
- `AccessSnapshot.administrators` counts people only, so the last human administrator can never be replaced by a bot.

`GET /me/organizations`, `GET /me/access` and logout remain available, so an integration can discover its organization and permissions.

## Risks / Trade-offs

- **Subject squatting.** An admin of organization A could register client X's subject before organization B does. Because `auth_subject` is unique, this blocks B; it grants A nothing, since only the client's secret holder can mint tokens. → Accepted for now. B sees `409`, and the operator resolves it. Revisit with proof of possession if it happens.
- **Owner approves the account's writes.** Requester exclusion applies to the service account, not to its owner. → Documented as customer configuration. Customers can keep owners out of the relevant approver groups.
- **Service accounts can be granted anything,** including approvals and membership management. → Customer responsibility, per the proposal non-goals. The audit trail attributes every use.
- **Synthetic name and email columns** could leak into person-oriented outputs. → Person-only surfaces filter by `kind`, and tests cover `GET /users` and `/me`.
- **An IdP can't issue client-credentials tokens for the configured audience,** or puts the subject somewhere other than `sub`. → Verify against each supported provider before release (task). Verification stays provider-agnostic.

## Migration Plan

This is pre-release, so the policy is to edit the `CreateUser` migration in place (adding `kind` and the check) and add a `CreateServiceAccount` migration with a change trigger and tenant foreign keys. Existing databases are rebuilt as usual for pre-release. Rollback is reverting the change.

## Open Questions

- Should `GET /service-accounts` offer a `lastUsedBefore` filter for "unused in N days" reviews, or should reviewers sort client-side?
- When an owner leaves the organization, should the account be flagged in the listing (for example, `ownerActive: false`), or is the owner's absence from `GET /users` enough evidence?
