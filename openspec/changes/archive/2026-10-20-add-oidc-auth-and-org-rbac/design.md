## Context

open-erp is a multi-tenant Vapor 4 / Fluent / Postgres back end. Tenancy is selected by `X-Organization-ID`, verified only for existence by `OrganizationMiddleware`. Tenant filtering already lives in `Model.query(on:organizationID:)` helpers, and cross-organization isolation is tested for companies. Users are global (unique email) and linked to organizations through `organization_users`; `company_users` exists for future company-level access. There is no authentication, audit fields are never populated, `POST /users` and `PATCH /users/:id` let anyone create or rewrite identities, and `POST /organization-users` lets any organization attach any user by UUID. `routes.swift` and `configure.swift` reference a `TodoController` and `CreateTodo` that no longer exist.

Constraints: open source, so no hard dependency on a single identity provider; designed for SOX and SOC controls; minimal code.

## Goals / Non-Goals

**Goals:**
- Provider-agnostic OIDC authentication, Auth0 by default.
- Per-request membership verification for the selected organization.
- Zero-trust, explicit RBAC at the organization level, with a schema that already supports company-scoped grants.
- Invite-first onboarding; identity owned by the person.
- Audit attribution on every write.

**Non-Goals:**
- Enforcing company-level permissions or company role assignment endpoints (next change).
- Subdomain or custom-domain tenant resolution.
- Approval workflows, privilege-escalation guards, last-administrator lockout guards (future change management).
- Sending invitation emails.
- Postgres row-level security.

## Decisions

### 1. Verify JWTs with `vapor/jwt` against the provider's JWKS
Use `vapor/jwt` 5.x (https://docs.vapor.codes/security/jwt/). At startup, fetch `OIDC_JWKS_URL` with `app.client` and load it with `app.jwt.keys.add(jwksJSON:)`. An `AccessToken: JWTPayload` declares only `iss`, `sub`, `aud`, `exp`; its `verify(using:)` checks `exp`, and `Request.verifiedAccessToken()` checks `iss` and `aud` against `app.oidc`, because the payload has no access to configuration without global state.

*Alternatives:* Auth0 SDK (vendor lock-in); provider introspection per request (network call on every request).

### 2. Org selected by header, authorized by membership
`X-Organization-ID` remains the selector. `OrganizationMiddleware` loads the active membership joined to a non-deleted organization; any miss is `403` so organization existence is not disclosed. The header is kept over URL paths because tenants will later be resolved from subdomains, which replaces only how the ID is found.

*Alternatives:* `org_id` claim via Auth0 Organizations (vendor-specific, forces token re-issue to switch organizations, breaks multi-tab, still needs a DB check for immediate revocation); server-side active-org session (stateful, breaks multi-tab).

### 3. Two small middlewares
- `AuthMiddleware`: verify token, load `User` by `auth_subject`, store it on the request. Used by `/me`, `/me/organizations`, `/platform/*`, and every organization-scoped route.
- `OrganizationMiddleware` (after `AuthMiddleware`): verify membership, then load the member's permission strings in one join (`role_permissions` → `roles` → `organization_role_assignments` → `organization_users`), and store `organizationID` and `permissions: Set<Permission>` on the request.

`POST /invitations/accept` verifies the token itself because the caller has no user yet.

Fluent applies soft-delete filtering only to the base model, so every joined table's `deleted_at IS NULL` is filtered explicitly.

### 4. Permission checks in handlers
Each handler starts with `try req.require(.companyRead)`, which throws `403` if the permission is not in `req.permissions`. One parameterized test walks the route-permission table from the spec: a member holding every permission except the one under test gets `403`. This catches forgotten or wrong checks without adding a route DSL.

*Alternative:* per-route middleware groups (more nesting in `boot`, same guarantee once the sweep test exists).

### 5. Permission catalog is a Swift enum
`enum Permission: String, CaseIterable` with raw values like `"company:read"` and a computed `level`. `role_permissions.permission` stores the raw string. Strings in the database that no longer decode to a case are ignored when loading, so removed permissions grant nothing. Templates are static values next to the enum.

*Alternative:* seeded `permissions` table with foreign keys (extra sync between code and data with no enforcement benefit, because only code can enforce a permission).

### 6. Scope is set by the table, never by nulls
`roles.level` is a required string (`organization`/`company`) with no default. Organization grants live in `organization_role_assignments(organization_user_id, role_id)`; company grants live in `company_role_assignments(organization_user_id, role_id, company_id)` with every column `.required`. A bug that drops `company_id` fails the insert instead of widening access. Company-level permissions can only ever be granted per company, so a new company starts with no access.

Assignments reference the membership rather than the user. Removing a member soft-deletes the membership and its assignments together, and re-inviting creates a new membership, so old grants are never resurrected. That role, membership, and company share an organization is checked in the create path; composite foreign keys can harden this later.

### 6a. History is kept as rows, never restored
Soft-deleted rows are never restored or overwritten: re-granting a role, re-inviting a member, or re-adding a permission inserts a new row, and removing one soft-deletes it with `deleted_by`. Uniqueness is therefore enforced by Postgres partial unique indexes `WHERE deleted_at IS NULL` (https://www.postgresql.org/docs/current/indexes-partial.html), created with SQLKit's `create(index:)` (https://api.vapor.codes/sqlkit/documentation/sqlkit/sqlcreateindexbuilder), and violations map to `409`. This also lets a deleted role's name be reused and closes check-then-insert races.

*Alternative:* restore soft-deleted rows (overwrites `created_by`/`deleted_by`, erasing who granted and revoked access).

### 7. Invitations with hashed, single-use tokens and `/userinfo`
Tokens are 32 random bytes, base64url-encoded, returned once; only `SHA256` is stored. Invitations expire after 7 days and are revoked by soft delete. On accept, the server calls the standard OIDC userinfo endpoint with the caller's bearer token to get `email` and `email_verified`. Clients must request the `openid email` scopes.

The userinfo call goes through a closure in `Application.storage` so tests can stub it.

*Alternative:* add an email claim with an Auth0 Action (provider-specific).

### 8. Platform administrator
`users.is_platform_admin` (`.required`, default `false`) is set only by a Vapor `AsyncCommand` registered as `platform-admin` (https://docs.vapor.codes/advanced/commands/). The command takes the OIDC subject explicitly, copied from the provider's user record, because platform admins are not created through invitations. `/platform/*` routes check the flag; organization routes ignore it.

### 9. Testing
In `.testing`, `configure` skips the JWKS fetch, adds a local ES256 key, and defaults the OIDC issuer and audience. A test helper signs tokens for a given subject and sets both `Authorization` and `X-Organization-ID`. Existing tests move to that helper.

### 10. Schema changes are new migrations
Add migrations instead of editing existing ones, so the migration history stays an audit record.

```
users                         + auth_subject (unique, nullable until bound), + is_platform_admin (required, default false)
organization_users            unique(organization_id, user_id) becomes active-only
organization_invitations      organization_id, email, first_name, last_name, role_id?, token_hash (unique),
                              expires_at, accepted_at?, accepted_by?, created_by, deleted_by, created_at, deleted_at
roles                         organization_id, name, level, template_key?, audit fields; active-unique(organization_id, name)
role_permissions              role_id, permission, created_by, deleted_by, created_at, deleted_at; active-unique(role_id, permission)
organization_role_assignments organization_user_id, role_id, created_by, deleted_by, created_at, deleted_at;
                              active-unique(organization_user_id, role_id)
company_role_assignments      organization_user_id, role_id, company_id, created_by, deleted_by, created_at, deleted_at;
                              active-unique(organization_user_id, role_id, company_id)
```

Tables created by this change get their indexes in their own migrations. `organization_users` predates it, so `ScopeOrganizationUserUniquenessToActiveRows` replaces its constraint; its revert drops the index without restoring the full-table constraint, because removed memberships kept as history would violate it.

`organization_invitations.role_id` is nullable because no role means less access, never more.

## Risks / Trade-offs

- [JWKS loaded once at boot; provider key rotation needs a restart] → Acceptable for now; add refresh-on-unknown-`kid` later.
- [A handler forgets `req.require`] → Route-permission sweep test from the spec table.
- [A joined soft-deleted row (membership, role, assignment) still grants access] → Explicit `deleted_at` filters on every join, plus revocation tests.
- [Anyone holding role or assignment permissions can grant themselves anything] → Accepted; future change management adds approvals.
- [Platform admin account compromise] → CLI-only flag, explicit subject binding, logged grants and revocations, no implicit tenant access.
- [Invitation token leakage] → Hashed at rest, single use, 7-day expiry, and acceptance requires a verified matching email.
- [Removing a permission from the enum leaves orphan strings] → Ignored at load time, so they grant nothing; clean up in the same migration.
- [Two queries per organization-scoped request] → Each join is covered by an active-unique index; acceptable compared with the risk of per-request caching of permissions.
- [A removed member's grants come back when they rejoin] → Removal revokes assignments, and rejoining creates a new membership.

## Migration Plan

Pre-production; no tenant data to preserve.

1. Configure the Auth0 tenant: an API whose identifier is `OIDC_AUDIENCE`, and an application allowed `openid email profile` scopes.
2. Set `OIDC_ISSUER`, `OIDC_AUDIENCE`, `OIDC_JWKS_URL`, `OIDC_USERINFO_URL`.
3. Run migrations.
4. Run `platform-admin` for the operator.
5. Provision organizations through `POST /platform/organizations` and deliver invitation tokens out of band.

Rollback: revert the new migrations and redeploy the previous build.

## Open Questions

- Should invitation expiry be configurable per deployment?
- JWKS refresh policy (interval vs. on unknown `kid`) when key rotation is first needed.
