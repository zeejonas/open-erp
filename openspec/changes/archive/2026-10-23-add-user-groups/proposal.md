## Why

Access is granted user by user today, so the number of assignments grows with users × roles × companies. A 10,000-person tenant can't maintain or review that, and every grant is an unnamed row. Groups give every grant a name and a single path, and they work just as well for a 5-person tenant.

## What Changes

- Add organization-owned **groups**: a named set of members, the roles they get, and the companies where they get them.
- A group's organization-level roles apply organization-wide. Its company-level roles apply at the group's eligible companies only. A group may mix both levels.
- Company eligibility is explicit and zero trust. A new company has no eligible groups until someone adds them.
- **BREAKING**: Groups become the only way to hold a role. Remove organization role assignments (`/organization-role-assignments`, its permissions, and its table) and the unenforced company role assignment table.
- **BREAKING**: Invitations take an optional `groupId` instead of `roleId`. Acceptance adds the new member to that group.
- Provisioning copies group templates ("Organization Administrators" and "Organization Viewers") alongside role templates, and invites the first administrator into "Organization Administrators".
- Removing a member also removes their group memberships.
- New permissions: `group:create|read|update|delete`, `group_member:create|read|delete`, `group_role:create|delete`, `group_company:create|delete`.

## Non-goals

- Enforcing company-level permissions. The catalog has none yet. This change defines and stores eligibility, and enforcement ships with the first company-scoped resource.
- Nested groups, permissions granted directly to groups, deny rules, and composite roles.
- Direct user-to-role grants, including one-off exceptions. An exception is a group of one.
- Eligibility that still needs a further per-company grant, and "all current and future companies" eligibility.
- Syncing groups from an identity provider (SCIM or group claims).
- Access review and segregation-of-duties reports.

## SOX / SOC Impact

- **Access control**: Zero trust is unchanged. A user holds a permission only through an active membership in an active group that holds an active role containing it. Company access is never inferred.
- **Audit trail**: Group membership, role attachment, and company eligibility are separate rows with `created_by` and `deleted_by`. Removing any of them is a soft delete, so the history of who could do what, where, and since when is kept.
- **Segregation of duties**: Managing who is in a group (`group_member:*`) is separate from managing what a group can do (`group_role:*`) and where (`group_company:*`). These can be held by different people. Holding group or grant permissions still allows self-escalation, as role assignment does today. Approvals remain future work.
- **Access reviews**: Reviewers certify a small number of named groups and their roles instead of every user's individual assignments.

## Capabilities

### New Capabilities
- `organization-groups`: Groups, group membership, group roles, company eligibility, group templates, and how they combine into a member's permissions.

### Modified Capabilities
- `organization-rbac`: The permission catalog and route table swap organization role assignment permissions for group permissions. Zero-trust enforcement resolves through groups. A role is in use when attached to a group. Organization role assignments and the company role assignment schema are removed.
- `organization-membership`: Invitations reference a group instead of a role. Acceptance adds the member to that group. Member removal soft-deletes group memberships.
- `platform-administration`: Provisioning copies group templates and invites the first administrator into the administrators group.

## Impact

- **Models and migrations**: New `groups`, `group_members`, `group_roles`, and `group_companies` tables. `organization_invitations.role_id` becomes `group_id`. The `organization_role_assignments` and `company_role_assignments` tables are removed. Following the pre-release migration policy, existing create migrations are edited in place.
- **Code**: Permission loading in `OrganizationMiddleware`, `Permission` and templates, `Role.isInUse`, and the invitation, organization-user, and platform controllers. A new `GroupController` replaces `OrganizationRoleAssignmentController`.
- **API**: New `/groups` routes. `/organization-role-assignments` is removed. The invitation request and response swap `roleId` for `groupId`.
- **Tests**: The `createMember` helper grants permissions through a group. Role assignment tests become group tests.
