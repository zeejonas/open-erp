## Why

Integrations (AP automation, banks, EDI, BI) will call the API directly as vendors, POs, receipts and bills land. Today they can only authenticate by borrowing a person's login, which misattributes their writes in audit and business events, grants everything that person can do, breaks when the person leaves, and gives later rate limits nothing to key on (GitHub issue #10).

## What Changes

- Add organization-owned **service accounts**: non-human principals stored as `users` rows with `kind = service`, each bound to exactly one organization through an `organization_users` membership and a 1:1 `service_accounts` record holding owner, description, disabled state and last-used time.
- Service accounts authenticate with **identity-provider client-credentials tokens**. The server does not mint credentials: an org admin creates the client in the IdP and registers the token's subject, which binds to `users.auth_subject`. Token verification is unchanged; credential rotation happens in the IdP.
- Permissions come only from the existing groups and roles. There is no server-side permission mask or ceiling for service accounts.
- Audit and business events attribute service account writes with actor type `service_account` and the account's ID. Every lifecycle change is audited.
- Creating, updating (including re-enabling and changing the bound subject) and deleting service accounts are approval-gateable. Disabling is immediate and never held, mirroring webhook emergency disable.
- A disabled or deleted service account is refused on its next request, even while its token is unexpired.
- Access reviews: `GET /service-accounts` lists each account with its owner, enabled state and last-used time. Last use is recorded at most once per day per account.
- Human-only surfaces exclude service accounts: `/me`, invitation acceptance, `GET /users`, member removal, platform administration, and the administrator-continuity count.

## Capabilities

### New Capabilities

- `service-accounts`: Registration, lifecycle (update, disable, re-enable, delete), owner, last-used tracking and listing of organization service accounts.

### Modified Capabilities

- `authentication`: A bound subject may resolve to a service account. Disabled service accounts are refused, and service accounts cannot use person-only identity routes.
- `audit-trail`: New actor type `service_account` for writes made by service accounts.
- `organization-rbac`: New `service_account:*` permissions, their routes, and the rule that service accounts never count as administrators.
- `approval-workflows`: Gate service account create, update and delete; expose update fields; exclude disable.
- `organization-membership`: Member listing and removal cover people only; a service account's membership ends only by deleting the account.

## Non-goals

- App-issued API keys, or minting IdP clients through provider management APIs.
- Server-enforced limits on what a service account may be granted (for example, blocking approvals or membership management). Guidance belongs in customer docs later.
- Seat, plan or billing accounting.
- Rate limits (#11) and cursor pagination (#12).
- Proving that the registering organization controls the IdP client before binding. This is revisited if subject squatting becomes a real problem.

## Impact

- **Code:** `users` and `service_accounts` create migrations (pre-release, edited in place); `User` and `ServiceAccount` models; `AuthMiddleware`, `Request.auditContext`, `AuditActorType`; `AccessSnapshot.administrators`; new controller, DTOs and OpenAPI; `ProposedChange` cases; person-only guards in `MeController`, `InvitationController`, `UserController` and `OrganizationUserController`.
- **APIs:** New `/service-accounts` routes. `GET /users` and its total exclude service accounts.
- **Business events** (pending webhooks change) inherit the new actor type through `AuditActorType`.
- **SOX/SOC:**
  - Integrations are attributed separately from people.
  - Each account has an accountable owner.
  - Lifecycle changes are audited and approval-gateable, and disable takes effect immediately.
  - Last-used evidence supports periodic access reviews.
  - Segregation of duties: requesters still cannot approve their own requests, but an account's owner can approve its held writes. This is documented as a customer configuration responsibility rather than enforced.
