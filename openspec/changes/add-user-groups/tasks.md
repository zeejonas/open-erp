## 1. Schema and models

- [x] 1.1 Add `CreateGroup`, `CreateGroupMember`, `CreateGroupRole`, and `CreateGroupCompany` migrations with required foreign keys and active-unique indexes, registered after `CreateRolePermission`
- [x] 1.2 Replace `role_id` with `group_id` in `CreateOrganizationInvitation`, register it after the group tables, and delete `CreateOrganizationRoleAssignment` and `CreateCompanyRoleAssignment`
- [x] 1.3 Add `AccessGroup` (with `@Children` for roles and companies), `GroupMember`, `GroupRole`, and `GroupCompany` models, plus `AccessGroup.query(on:organizationID:)`
- [x] 1.4 Delete the `OrganizationRoleAssignment` and `CompanyRoleAssignment` models and `OrganizationRoleAssignmentController`. Swap `role` for `group` on `OrganizationInvitation`
- [x] 1.5 Extend `SchemaTests`: duplicate active rows in each group table are rejected

## 2. Permissions and enforcement

- [x] 2.1 Replace the `organization_role_assignment:*` cases with the `group`, `group_member`, `group_role`, and `group_company` permissions
- [x] 2.2 Rewrite `loadPermissions` to join through `group_roles`, `groups`, and `group_members`, filtering organization, organization-level roles, and `deleted_at` on every joined table
- [x] 2.3 Change `createMember(permissions:)` to grant through a role, a group, and a group membership
- [x] 2.4 Test zero trust: no groups, a group with no roles, a deleted group, a removed group membership, a detached role, and a group in another organization all respond `403`. Test that a removed assignment permission is rejected on role create

## 3. Groups API

- [x] 3.1 Add the group DTOs and `GroupController` with `POST/GET /groups` and `GET/PATCH/DELETE /groups/:groupID`, where the detail and list responses include role and company IDs
- [x] 3.2 Add `POST/GET /groups/:groupID/members` and `DELETE /groups/:groupID/members/:userID`
- [x] 3.3 Add `POST /groups/:groupID/roles` and `DELETE /groups/:groupID/roles/:roleID`, allowing either role level
- [x] 3.4 Add `POST /groups/:groupID/companies` and `DELETE /groups/:groupID/companies/:companyID`
- [x] 3.5 Register `GroupController` in `routes.swift` and remove the role assignment controller
- [x] 3.6 Update the route-permission sweep with every group route, and test that `/organization-role-assignments` is `404`
- [x] 3.7 Test groups: create, duplicate name `409`, delete in use `409`, and another organization's group `404` on read, update, and delete
- [x] 3.8 Test membership: add member, non-member `404`, duplicate `409`, and removal takes effect on the next request with `deleted_by` set
- [x] 3.9 Test roles and companies: attach grants immediately, mixed levels allowed, a role or company from another organization (or a deleted company) `400`, duplicate `409`, and removing the only eligible company keeps organization-level permissions
- [x] 3.10 Deleting a company soft-deletes its group eligibility with `deleted_by` in the same transaction, and test it

## 4. Roles

- [x] 4.1 Change `Role.isInUse` to "attached to an active group"
- [x] 4.2 Test that deleting a role attached to an active group is `409`, and that a role attached only to a deleted group can be deleted

## 5. Invitations and membership

- [x] 5.1 Change invitation create to take `groupId`, requiring an active group in the organization
- [x] 5.2 Change acceptance to re-check the group inside the transaction and insert a `group_members` row
- [x] 5.3 Change member removal to soft-delete the member's group memberships along with the membership
- [x] 5.4 Update invitation tests: a group from another organization or a deleted group `400`, acceptance joins the group, a group deleted before acceptance `400` with nothing persisted, and a re-invited member's old groups grant nothing
- [x] 5.5 Update the member removal test to check that group memberships are soft-deleted with `deleted_by`

## 6. Provisioning

- [x] 6.1 Add `GroupTemplate` (`org_admins`, `org_viewers`) and `AccessGroup.copyTemplates`, called in the provisioning transaction, and point the first invitation at `org_admins`
- [x] 6.2 Test provisioning: both template groups exist with their roles, the accepted first administrator holds every organization-level permission, and an edit to a copied group stays within its organization

## 7. Finish

- [x] 7.1 Run `swift build` and `swift test`, and confirm `openspec validate add-user-groups` passes
