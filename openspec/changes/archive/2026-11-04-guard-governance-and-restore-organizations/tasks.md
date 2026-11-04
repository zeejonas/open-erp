## 1. Access snapshot

- [x] 1.1 Add `AccessSnapshot` loading active memberships and group grants for an organization, with pure helpers for removing a member, group member, group role, or role permissions
- [x] 1.2 Unit test administrators and permission holders from a snapshot, including removed links

## 2. Administrator continuity

- [x] 2.1 Add the before/after administrator guard to `ProposedChange.check` for the four reducing changes, taking `lockOrganization` first
- [x] 2.2 Test each reducing route returning `409`, and a removal succeeding while another administrator remains
- [x] 2.3 Test that an organization already without an administrator is not blocked
- [x] 2.4 Test a held removal ending `failed` when another removal applied first, and concurrent removals leaving an administrator

## 3. Policy satisfiability

- [x] 3.1 Add the stage check to `validatePolicy` using `stageIsComplete`, excluding each possible requester, with the invitation case for `group_member:create`
- [x] 3.2 Add the before/after removal guard for `groupMemberDelete` and `organizationUserDelete`
- [x] 3.3 Test the sole approver, one person in two slots, an approver who cannot request, and a two-approver group
- [x] 3.4 Test the removal `409`, and that an already-unsatisfiable policy does not block a removal
- [x] 3.5 Update existing fixtures that the new rule rejects

## 4. Access discovery

- [x] 4.1 Add `GET /me/access` with its DTO and OpenAPI annotations
- [x] 4.2 Test sorted permissions, per-organization differences, no group, non-member `403`, and a missing header `400`
- [x] 4.3 Add `GET /permissions` with `level` filter, `role:read`, and OpenAPI annotations
- [x] 4.4 Test paging, strict parameters, every catalog entry present, and `403` without `role:read`

## 5. Organization restore

- [x] 5.1 Add `CreateOrganizationRestoration` with the append-only trigger, its model, and registration
- [x] 5.2 Add the `deleted` filter and `deletedAt`/`deletedById` on platform organization items
- [x] 5.3 Add `POST /platform/organizations/:organizationID/restore` with a required reason, row lock, evidence row, attribution, and notice log
- [x] 5.4 Test restore end to end: members regain access with memberships intact, and the evidence row keeps the original deletion
- [x] 5.5 Test `400` without a reason, `404` for unknown or malformed IDs, `409` for an active organization, `403` for a non-platform user, no tenant access granted, and that evidence rows reject update and delete
- [x] 5.6 Test the `deleted` filter and that default listing and detail still hide deleted organizations

## 6. Contract and docs

- [x] 6.1 Update the README route table and the export/OpenAPI tests for 57 operations
- [x] 6.2 Run `swift test`
