## Context

Every write goes through `ProposedChange`. `ApprovalService.submit` runs `check` then applies or holds inside one transaction, and `applyApproved` runs `check` again before applying. A failure at apply marks the request `failed` with the reason. Holding a change therefore needs guards in `check` only.

Permissions come only through member → group → role → grant. `template_key` must not influence access, so "administrator" cannot mean "member of Organization Administrators".

Deleting an organization soft-deletes the organization row alone. Members, groups, and roles stay intact, and `OrganizationMiddleware` then refuses everyone. `organizations.code` is unique across deleted rows, so a restore cannot collide on code.

## Goals / Non-Goals

**Goals:** keep every organization administrable; make every saved policy completable; let any client read its caller's access and the catalog; make organization deletion recoverable with evidence.

**Non-Goals:** see the proposal.

## Decisions

### An administrator holds every organization-level permission

The guard counts active members whose effective permissions equal `Permission.allCases`. This is the product decision for now, and the simplest rule to explain to an auditor.

Templates are copied, so a permission added later leaves existing administrators short of "every". The guard therefore refuses only a change that takes the count from above zero to zero. An organization already at zero is not blocked from any change.

*Rejected:* a minimal recovery permission set (more to explain, and not what was chosen); checking `template_key` (forbidden by the spec); requiring two administrators (blocks ordinary single-admin onboarding).

### Guards simulate the change against an access snapshot

`check` loads an `AccessSnapshot` of active memberships and group grants for the organization. It removes what the change would remove, then evaluates the pure rules on the before and after values. Only `organizationUserDelete`, `groupMemberDelete`, `groupRoleDelete`, and a `roleUpdate` that removes permissions can reduce administrators. `roleDelete` and `groupDelete` are already refused while in use.

Running in `check` covers immediate writes, held submissions, final approvals, and both overrides. A request that became unsafe while pending ends `failed`, and the existing transaction rollback applies. [Fluent transactions](https://docs.vapor.codes/fluent/transaction/) abandon all writes when the closure throws.

*Rejected:* checking the count after `apply` and rolling back (cannot refuse a held change at submission); a database trigger (spreads the permission model into SQL).

### Serialize with the organization row lock

Guarded changes take the existing `lockOrganization` (`FOR NO KEY UPDATE`) before reading the snapshot, so two concurrent removals cannot each see the other administrator. This also covers policy creation and update racing a member removal. [`FOR NO KEY UPDATE`](https://www.postgresql.org/docs/current/explicit-locking.html#LOCKING-ROWS) serializes these writers without blocking the `FOR KEY SHARE` that foreign-key checks take. Onboarding already relies on this helper, so it is not a new pattern.

*Rejected:* serializable isolation with retries (retries everywhere for a rare race).

### A policy must be completable without any one possible requester

For each stage, approvers are the stage's group members. The stage must pass `stageIsComplete`, which already implements one-slot-per-approver matching, with all of them. It must also pass with each member removed who could raise the request, because a requester cannot approve their own request.

A possible requester is a member holding the policy's permission. A policy on `group_member:create` also gates invitations into a group, so holders of `organization_invitation:create` count too.

A failed save responds `400`, like other invalid definitions. A member removal that takes an active policy from satisfiable to unsatisfiable responds `409`, like `groupDelete` does for a group in use. Comparing before and after means an already-unsatisfiable policy never blocks unrelated removals.

Self-gating policies need no rule. If approvers always exist, a policy on `approval_policy:delete` can be completed like any other. `approval-override` remains the last resort.

*Rejected:* excluding every member in turn (rejects a valid one-person approver group whose member cannot make the request); only counting slot sizes (misses one person filling two slots).

### `GET /me/access` is a resource, not a collection

It returns `{ organizationId, permissions }`, sorted, from the `req.permissions` that `OrganizationMiddleware` already loads. Its permission array is an attribute, like `permissions` on a role. A paged form would let a client read 25 of 33 and silently hide things.

It sits on `/me` because it describes the caller, and requires `X-Organization-ID` because access differs per organization. It requires no permission beyond active membership.

*Rejected:* adding permissions to `/me` (`/me` has no organization); adding them to `/me/organizations` (expensive per row, and stale across a long list); probing routes (fails the API's own explicit-access model).

### `GET /permissions` follows list-endpoints

The catalog is a collection, so it uses the paged envelope with a `level` filter. Rows are defined in code and have no timestamp, so the order is `permission` ascending. It requires `role:read`, since it exists to let role managers choose grants. Each item is `{ permission, level }`.

*Rejected:* widening `/approval-catalog` (that list means "can require approval", and its entries carry different fields); a bare array (breaks list-endpoints).

### Restore is a platform operation with an append-only record

Tenants cannot reach a deleted organization, so restoring belongs to `PlatformAdminMiddleware`. In one transaction, the route locks the row, inserts into `organization_restorations`, clears the delete with Fluent's [`restore(on:)`](https://docs.vapor.codes/fluent/model/#soft-delete), clears `deleted_by`, and sets `updated_by`. It finds the row with [`withDeleted()`](https://docs.vapor.codes/fluent/model/#soft-delete), because Fluent excludes soft-deleted rows from normal queries.

The new table holds `organization_id`, `deleted_at`, `deleted_by`, `restored_by`, `reason`, and `created_at`. It uses the existing `createAuditTrigger` with no protected columns, so every update and delete is rejected. It gets one create migration, per the pre-release policy.

`GET /platform/organizations?deleted=true` lists only deleted organizations. Without the filter, behavior is unchanged. `GET /platform/organizations/:id` still returns `404` for a deleted organization, so onboarding detail and reissue stay limited to live organizations.

*Rejected:* a time-limited window (needs a purge job and a retention decision nobody has asked for); a CLI-only restore (the platform console should own this); tenant-side undo (no member can reach a deleted organization).

## Risks / Trade-offs

- [The snapshot query runs on each guarded write] → Only these writes pay for it, and they are infrequent administrative actions.
- [A later grant can make a sole approver a possible requester] → Their own request can be withdrawn or overridden. Blocking an ordinary grant for this would surprise administrators.
- [Pending tracks are pinned to old policy versions, and the removal guard only reads active policies] → A pending request can still strand. `approval-override` and withdrawal cover it.
- [A restore revives pending invitations and requests] → They were already valid before deletion and still pass their own checks. Expired invitations stay expired.
- [Existing tests may build policies a sole approver could not satisfy] → Update those fixtures so the approver does not hold the gated permission.

## Migration Plan

Pre-release: add `CreateOrganizationRestoration` after `CreateOrganization` and `CreateUser`. Rollback reverts the migration. Refresh `open-erp-ui/contract/openapi.json` from `export-openapi` after merge. Any already-saved unsatisfiable policy stays as it is and can be edited or deleted.

## Open Questions

None.
