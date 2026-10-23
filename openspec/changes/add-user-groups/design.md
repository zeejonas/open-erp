## Context

Today a member holds a role through an `organization_role_assignments` row on their membership. `company_role_assignments` exists but nothing enforces it. `OrganizationMiddleware.loadPermissions` joins `role_permissions → roles → organization_role_assignments → organization_users` on every request. Invitations carry an optional `role_id`. Provisioning copies role templates and invites the first administrator with the Organization Administrator role. Every permission in the catalog is organization-level, so a company-level role cannot hold any permission yet. The project is pre-production.

## Goals / Non-Goals

**Goals:**
- One path to a role: membership → group → role.
- Company scope set by explicit eligibility rows, with nothing nullable.
- Keep the per-request, uncached permission load so revocation takes effect on the next request.
- No raw SQL beyond the existing active-unique index helper.

**Non-Goals:**
- Enforcing company-level permissions, and choosing how a request names its company.
- Identity-provider group sync, nested groups, and access-review or segregation-of-duties reports.
- Self-escalation guards and approvals.

## Decisions

### 1. Four flat tables, all columns required
```
groups            organization_id, name, template_key?, created_by, updated_by, deleted_by, timestamps
                  active-unique(organization_id, name)
group_members     group_id, organization_user_id, created_by, deleted_by, created_at, deleted_at
                  active-unique(group_id, organization_user_id)
group_roles       group_id, role_id, created_by, deleted_by, created_at, deleted_at
                  active-unique(group_id, role_id)
group_companies   group_id, company_id, created_by, deleted_by, created_at, deleted_at
                  active-unique(group_id, company_id)
```
Each table states one fact, so the Fluent schema builder expresses all of it (https://docs.vapor.codes/fluent/schema/). Uniqueness reuses `createActiveUniqueIndex`, and violations map to `409` through `conflictOnDuplicate`, as for roles. A role's level decides where it applies, so no row carries a scope column.

*Rejected:* a single assignment table with a nullable `company_id` and a CHECK (needs raw SQL and a copied `role_level` column); a (group, role, company) triple (a group could no longer be read as one sentence).

### 2. Group members reference the organization membership
`group_members.organization_user_id`, not `user_id`, the same as role assignments do today. Removing a member soft-deletes the membership and its group memberships in one transaction (https://docs.vapor.codes/fluent/transaction/). Re-inviting creates a new membership, so old groups never come back.

*Rejected:* referencing `users` (rejoining would resurrect old access).

### 3. Pivots are explicit models, not `@Siblings` attach/detach
`@Siblings.detach` deletes the pivot row (https://docs.vapor.codes/fluent/relations/#siblings-attach), which would lose `deleted_by`. `GroupMember`, `GroupRole`, and `GroupCompany` are plain models with `@Parent` fields. They are created with `save` and removed with the existing `softDelete(by:)`. `AccessGroup` declares `@Children` for its roles and companies so `GET /groups` can eager-load them in one extra query each. The model is named `AccessGroup` rather than `Group` because Fluent's `@Group` property wrapper shadows `Group` inside model types. The table, routes, and child models keep the `group` name. Eager loading queries the child model, so soft-deleted rows are excluded (https://docs.vapor.codes/fluent/relations/#eager-loading).

### 4. Permission loading walks groups
`loadPermissions` keeps its shape with one more hop, joining `role_permissions → roles → group_roles → groups → group_members → organization_users` (https://docs.vapor.codes/fluent/query/#join). It filters on:
- The user and the organization on `organization_users`.
- `roles.organization_id` and `groups.organization_id` both equal to the organization.
- `roles.level = organization`.
- `deleted_at IS NULL` on every joined table, because Fluent filters soft deletes only on the base model.

It remains the single function that turns stored grants into permissions. Future company enforcement and access reports extend it rather than reimplementing it. Company eligibility is stored and validated but not read here until a company-level permission exists.

*Rejected:* a Postgres view (no SQLKit or Fluent builder for views; raw SQL for no gain today); caching permissions (delays revocation).

### 5. Routes nested under the group
`GroupController` registers `/groups` with child collections `members`, `roles`, and `companies`, using route groups (https://docs.vapor.codes/basics/routing/#route-groups) behind `AuthMiddleware` and `OrganizationMiddleware`. Each handler begins with `req.require(_:)`.
- The path group is looked up with `AccessGroup.query(on:organizationID:)`, so another organization's group is `404`.
- IDs in the request body (role, company, user) are checked against the organization. A role or company from elsewhere is `400`, a non-member user is `404`. This matches the existing assignment and invitation behavior.
- Child deletes are addressed by the related ID (`/members/:userID`, `/roles/:roleID`, `/companies/:companyID`), because the active-unique index guarantees at most one active row.

Member lists can be large, so they have their own endpoint and permission (`group_member:read`). Role and company IDs are small and come back on the group under `group:read`, so `group_role` and `group_company` need no read permission.

### 6. Delete rules
- **Group:** `409` while it has active members or pending invitations. Its role and company rows are left as they are. Every permission join filters `groups.deleted_at`, so they grant nothing, and the history stays exactly as it was when the group was deleted.
- **Company:** Deleting a company soft-deletes its `group_companies` rows with `deleted_by` in the same transaction. Unlike a deleted group, a deleted company stays referenced from active groups, so without this `GET /groups` would keep listing it in `companyIds`, and eligibility would point at a company that no longer exists.
- **Role:** `isInUse` becomes "has an active `group_roles` row on an active group". Pending invitations no longer reference roles.

*Rejected:* cascading soft deletes to role and company rows on group delete (more writes, no access difference).

### 7. Templates
`GroupTemplate(key, name, roleKeys)` lives next to `RoleTemplate`. `AccessGroup.copyTemplates(into:roles:createdByID:on:)` runs inside the provisioning transaction after `Role.copyTemplates` and attaches roles by `template_key`. `template_key` is reporting only, as for roles. The provisioning invitation names the `org_admins` group.

### 8. Invitations carry a group
`organization_invitations.role_id` is replaced by an optional `group_id`. Creating an invitation requires an active group in the organization. Acceptance re-checks it inside the transaction (`400` if it was deleted) and inserts a `group_members` row with `created_by` set to the accepting user.

### 9. Schema changes follow the pre-release migration policy
Per `openspec/config.yaml` (see consolidate-prerelease-migrations), create migrations are edited in place before release:
- New: `CreateGroup`, `CreateGroupMember`, `CreateGroupRole`, `CreateGroupCompany`.
- `CreateOrganizationInvitation` declares `group_id` instead of `role_id` and is registered after the group tables, since migrations are listed in dependency order (https://docs.vapor.codes/fluent/migration/#register).
- `CreateOrganizationRoleAssignment` and `CreateCompanyRoleAssignment` are deleted, along with the `OrganizationRoleAssignment` and `CompanyRoleAssignment` models and `OrganizationRoleAssignmentController`.

*Rejected:* alter and drop migrations (pre-release databases are disposable, so they only add files and revert code).

### 10. Tests
`createMember(permissions:)` builds a role, a group holding it, and a group membership, so existing tests keep their call sites. The route-permission sweep picks up the new rows from the spec table. New tests cover the spec's isolation, duplicate, deletion, and revocation scenarios. No company-enforcement tests, since there is nothing to enforce yet.

## Risks / Trade-offs

- [One extra join per organization-scoped request] → Each join is on an indexed foreign key with an active-unique index. Per-user cardinality is small. Acceptable compared with caching.
- [Different roles at different companies need separate groups] → Intended. Each group stays one reviewable sentence.
- [Unchecking a company leaves the group's organization-level permissions] → Specified behavior, covered by a scenario.
- [Holders of `group_member:create` or `group_role:create` can escalate themselves] → Same as today's assignment permissions. The split permissions let a tenant separate who-duties from what-duties. Approvals are future work.
- [Eligibility stored but unenforced] → Only possible because no company-level permission exists. The first company-scoped permission ships with enforcement and tests.
- [Deleting the last administrator group's last member locks the tenant out] → Unchanged from today. Lockout guards remain future work.

## Migration Plan

Pre-production; no tenant data to preserve. Drop the local database, run migrations, and re-provision local organizations so they receive template groups. Rollback: redeploy the previous build and reset the local database again.

## Open Questions

- How a company-scoped request names its company (path segment or header). This is decided with company enforcement.
Answer: use a header
