## 1. Setup

- [x] 1.1 Remove dangling `TodoController` and `CreateTodo` references and confirm `swift build` passes
- [x] 1.2 Add `vapor/jwt` 5.x to `Package.swift` and the app target
- [x] 1.3 Read OIDC env vars in `configure`; fail startup outside `.testing` if any is missing
- [x] 1.4 Fetch JWKS at startup and load with `app.jwt.keys.use(jwksJSON:)`; in `.testing`, add a local ES256 key instead

## 2. Schema

- [x] 2.1 Migration: add `auth_subject` (unique, nullable) and `is_platform_admin` (required, default false) to `users`; update `User` model
- [x] 2.2 Migration and model: `roles` with required `level`, `template_key`, audit fields, unique `(organization_id, name)`
- [x] 2.3 Migration and model: `role_permissions` with unique `(role_id, permission)`
- [x] 2.4 Migration and model: `organization_role_assignments` with required columns, audit fields, soft delete
- [x] 2.5 Migration and model: `company_role_assignments` with required `organization_user_id`, `role_id`, `company_id`, audit fields, soft delete
- [x] 2.6 Migration and model: `organization_invitations` with unique `token_hash`, expiry, acceptance and audit fields, soft delete

## 3. Permissions and templates

- [x] 3.1 `Permission` enum with the catalog from the spec, raw `resource:action` values, and `level`
- [x] 3.2 `RoleLevel` enum and `RoleTemplate` statics for Organization Administrator and Organization Viewer
- [x] 3.3 `req.require(_:)` that throws `403` when the permission is not in `req.permissions`

## 4. Authentication

- [x] 4.1 `AccessToken: JWTPayload` verifying `iss`, `aud`, `exp`
- [x] 4.2 `AuthMiddleware`: verify token, load user by `auth_subject`, `403` if unbound; expose `req.user`
- [x] 4.3 `GET /me` and `PATCH /me` (first/last name only, sets `updated_by`)
- [x] 4.4 Remove `POST /users` and `PATCH /users/:userID`

## 5. Organization membership

- [x] 5.1 Rewrite `OrganizationMiddleware`: parse header, verify active membership in a non-deleted organization (`403` otherwise), load permissions through joins with explicit `deleted_at` filters
- [x] 5.2 `GET /me/organizations`
- [x] 5.3 Userinfo fetcher closure in `Application.storage`, defaulting to `OIDC_USERINFO_URL` with the caller's bearer token
- [x] 5.4 Invitations controller: create (hashed token, 7-day expiry, optional same-org organization-level role), list pending, revoke
- [x] 5.5 `POST /invitations/accept`: verify token, userinfo check, find-or-create user, bind subject, create or restore membership, assign role, mark accepted — all in one transaction
- [x] 5.6 Replace `POST /organization-users` with invitations; keep `DELETE /organization-users/:userID` and set `deleted_by`

## 6. RBAC endpoints and enforcement

- [x] 6.1 Roles controller: CRUD with level validation, catalog validation, unique names, immutable level, `409` when deleting a role in use
- [x] 6.2 Organization role assignments controller: create (organization-level, same-org role, active member, no duplicates), list, revoke
- [x] 6.3 Add `req.require` to every route in the spec's route-permission table (organization, companies, users, organization-users, invitations, roles, assignments)
- [x] 6.4 Populate `created_by`, `updated_by`, `deleted_by` from the authenticated user in every controller

## 7. Platform administration

- [x] 7.1 `platform-admin` `AsyncCommand`: create or update user by email and subject, set or `--revoke` flag, fail on subject conflict, log the action
- [x] 7.2 `POST /platform/organizations`: platform-admin only; in one transaction create organization, copy templates, create first-admin invitation with Organization Administrator role; return organization and token
- [x] 7.3 Remove `POST /organizations`

## 8. Tests

- [x] 8.1 Test helpers: sign tokens for a subject, set `Authorization` and `X-Organization-ID`, stub userinfo, create a member with given permissions
- [x] 8.2 Migrate existing tests to authenticated requests
- [x] 8.3 Authentication: missing, bad-signature, wrong issuer or audience, expired, and unbound-subject tokens
- [x] 8.4 Membership: non-member, unknown organization, removed membership, deleted organization all `403`
- [x] 8.5 Route-permission sweep: for each route in the spec table, a member holding every permission except the required one gets `403`
- [x] 8.6 Invitations: acceptance happy path, existing user joining a second organization, unverified email, mismatch, subject conflict, expired, revoked, reused
- [x] 8.7 Roles and assignments: level mismatch, unknown permission, duplicate name, delete in use, revoked assignment loses access
- [x] 8.8 Platform: provisioning creates organization, roles, invitation; non-admin `403`; platform admin without membership `403` on organization routes
- [x] 8.9 Company role assignment insert without `company_id` is rejected by the database

## 9. Review fixes

- [x] 9.1 Removing a member soft-deletes its organization and company role assignments; acceptance creates a new membership instead of restoring one (test: remove, re-invite with no role, `403`)
- [x] 9.2 Active-only unique indexes for memberships, roles, role permissions, and role assignments; unique violations map to `409` (test: reuse a deleted role's name, duplicate organization code)
- [x] 9.3 Re-granting a revoked assignment inserts a new row (test: two rows, revoked one keeps `deleted_by`)
- [x] 9.4 Role permissions carry audit fields and are soft-deleted on removal (test: removed grant has `deleted_by`)
- [x] 9.5 Role deletion is blocked by pending invitations; acceptance ignores invitations to deleted organizations (tests)
- [x] 9.6 Verify `iss`/`aud` against `app.oidc` and remove global OIDC state
- [x] 9.7 `platform-admin` matches email case-insensitively; userinfo accepts string `email_verified` (test)
- [x] 9.8 `Model.softDelete(by:_:on:)` saves `deleted_by` and soft-deletes in one transaction
