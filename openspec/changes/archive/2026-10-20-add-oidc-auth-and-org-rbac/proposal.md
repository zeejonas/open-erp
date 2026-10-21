## Why

Every org-scoped route currently trusts a bare `X-Organization-ID` header, so anyone who knows an organization UUID can read and modify its data, and audit fields (`created_by`, `updated_by`, `deleted_by`) are never populated. Before any financial data lands in the system we need authenticated identity, verified organization membership on every request, and explicit, zero-trust permissions — without locking self-hosters into a single identity provider.

## What Changes

- Authenticate every non-public request with an OIDC access token (Auth0 by default) verified against the provider's JWKS; only standard claims (`iss`, `sub`, `aud`, `exp`) are used, so any OIDC provider works via configuration.
- `X-Organization-ID` remains the tenant selector, but the server now verifies the caller is an active member of that organization on every request. **BREAKING**: org-scoped routes require `Authorization: Bearer`.
- Separate identity from membership: users own their name via `/me`; organizations only manage membership. **BREAKING**: remove `POST /users` and `PATCH /users/:id`.
- Invite-first onboarding with no just-in-time sign-up: users are created only by accepting an invitation whose email matches a verified email from the provider's `/userinfo`. **BREAKING**: `POST /organization-users` (link by UUID) is replaced by invitations.
- Zero-trust RBAC: a code-defined permission catalog using `resource:create|read|update|delete`, per-organization roles copied from code-defined templates, and explicit role assignments. Roles have a level (`organization` or `company`); organization-level and company-level assignments live in separate tables with `NOT NULL` scope, so no grant is ever implied by a missing value.
- `company_role_assignments` is created now to fix the schema; enforcement of company-level permissions comes in a follow-up change.
- Platform administrator flag (`users.is_platform_admin`), settable only via CLI, that can provision an organization: create it, copy role templates, and invite its first Organization Administrator. **BREAKING**: `POST /organizations` moves to `POST /platform/organizations`.
- Populate audit fields from the authenticated user.

## Capabilities

### New Capabilities
- `authentication`: OIDC access-token verification, identity binding (`auth_subject`), `/me` endpoints, and provider-agnostic configuration.
- `organization-membership`: tenant selection via header, per-request membership verification, invitations and acceptance, member listing and removal.
- `organization-rbac`: permission catalog, role templates, roles, role permissions, organization and company role assignments, and per-request permission enforcement.
- `platform-administration`: platform admin flag, CLI bootstrap, and organization provisioning.

### Modified Capabilities

None (no existing specs).

## Impact

- **Dependencies**: add `vapor/jwt` 5.x.
- **Configuration**: new env vars `OIDC_ISSUER`, `OIDC_AUDIENCE`, `OIDC_JWKS_URL`, `OIDC_USERINFO_URL`.
- **Schema**: alter `users`; new `organization_invitations`, `roles`, `role_permissions`, `organization_role_assignments`, `company_role_assignments`.
- **Code**: `OrganizationMiddleware` rewritten; new `AuthMiddleware`; controllers gain permission checks and audit-field population; `UserController`, `OrganizationController`, `OrganizationUserController` reshaped; new invitation, role, assignment, `/me`, and platform controllers; new CLI command.
- **Clients**: must obtain an access token and send it with `X-Organization-ID`.
- **Tests**: test environment signs tokens with a local key and stubs `/userinfo`; existing tests updated to authenticate.
- **Out of scope**: company-level permission enforcement, subdomain/custom-domain tenant resolution, change-management approval flows, privilege-escalation guards, invitation email delivery.
