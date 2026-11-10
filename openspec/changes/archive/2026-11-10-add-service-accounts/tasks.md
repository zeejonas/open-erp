## 1. Schema and models

- [x] 1.1 Edit `CreateUser` in place: add required `kind` (`person` default) and the `CHECK (kind = 'person' OR NOT is_platform_admin)`; add `UserKind` and `User.kind`; test that a service user cannot be a platform admin
- [x] 1.2 Add `CreateServiceAccount` (shared primary key with `users.id`, `organization_id`, `owner_id`, `description`, `disabled_at`, `disabled_by`, `last_used_at`, attribution and timestamps), with tenant foreign keys and a change trigger, plus the `ServiceAccount` model; audit coverage test passes

## 2. Authentication and attribution

- [x] 2.1 Add `AuditActorType.serviceAccount`; derive it in `Request.auditContext()` from `kind`; test that a service account's company create records `service_account` and `created_by`
- [x] 2.2 In `AuthMiddleware`, refuse service accounts that are missing, deleted or disabled with `403`; test that a live token is refused right after disable
- [x] 2.3 Record last use with a conditional, audited SQLKit update at most once per 24 hours, logging failures without failing the request; test both first use and repeated use
- [x] 2.4 Refuse service accounts on `GET /me`, `PATCH /me` and invitation acceptance; test, and confirm `GET /me/access` still works

## 3. Permissions and person-only surfaces

- [x] 3.1 Add the `service_account:*` permissions (viewer template gets `read` through `isRead`); test route enforcement
- [x] 3.2 Count only people in `AccessSnapshot.administrators`; test that a bot holding every permission does not count as the last administrator
- [x] 3.3 Filter `GET /users` and `GET /users/:userID` to people, make `DELETE /organization-users/:userID` respond `404` for service accounts, and add `kind` to group member output; test each

## 4. Service account API

- [x] 4.1 Add DTOs and validation (name, description, subject, ownerId, enabled), plus owner eligibility checks (active person member of the same organization)
- [x] 4.2 Add `ProposedChange` cases for create, update and delete, with apply-time rechecks of subject uniqueness and owner; register them in `ApprovalCatalog` (`service_account:update` fields); test held registration, held re-enable, and subject taken before apply
- [x] 4.3 Implement `POST /service-accounts`: user plus membership plus account in one audited transaction, with `409` on a bound subject; test tenant isolation and conflict
- [x] 4.4 Implement `GET /service-accounts` (filters `name`, `enabled`, `ownerId`, ordered by `createdAt`) and `GET /service-accounts/:id`; test the cross-organization `404`
- [x] 4.5 Implement `PATCH /service-accounts/:id`, including subject replacement; test that the old subject is refused and the new one is accepted
- [x] 4.6 Implement `POST /service-accounts/:id/disable` as immediate, idempotent and never held; test with an approval policy present
- [x] 4.7 Implement `DELETE /service-accounts/:id`: soft-delete account, user, membership and group memberships, then clear `auth_subject`; test attribution retained and subject reusable
- [x] 4.8 Add OpenAPI annotations and regenerate the published contract

## 5. Documentation

- [x] 5.1 Verify client-credentials tokens against Auth0, Okta and Entra ID docs (issuer, audience, `sub` format); document how to create the client and which subject to register
- [x] 5.2 Document the customer responsibilities: what to grant, keeping owners out of approver groups for their accounts, and periodic review using last-used time
