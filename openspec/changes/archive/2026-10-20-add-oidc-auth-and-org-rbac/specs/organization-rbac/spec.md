## ADDED Requirements

### Requirement: Permission catalog
The system SHALL define permissions in code as `resource:action`, where action is one of `create`, `read`, `update`, `delete`, and each permission has a level of `organization` or `company`. Every permission in the catalog SHALL be enforced by at least one route. This change SHALL define the following organization-level permissions:

- `organization:read`, `organization:update`, `organization:delete`
- `company:create`, `company:read`, `company:update`, `company:delete`
- `organization_user:read`, `organization_user:delete`
- `organization_invitation:create`, `organization_invitation:read`, `organization_invitation:delete`
- `role:create`, `role:read`, `role:update`, `role:delete`
- `organization_role_assignment:create`, `organization_role_assignment:read`, `organization_role_assignment:delete`

#### Scenario: Unknown permission rejected
- **WHEN** a client creates or updates a role with a permission string not in the catalog
- **THEN** the system responds `400 Bad Request`

### Requirement: Zero-trust enforcement
A user SHALL hold a permission in an organization only if an active organization role assignment links their active membership to a role in that organization whose permissions include it. No permission SHALL be implied by a missing, null, or default value, by template origin, or by the platform administrator flag.

#### Scenario: Granted permission
- **WHEN** a member assigned a role containing `company:read` calls `GET /companies`
- **THEN** the system responds `200 OK`

#### Scenario: Missing permission
- **WHEN** a member with no role containing `company:create` calls `POST /companies`
- **THEN** the system responds `403 Forbidden` and nothing is created

#### Scenario: Member with no roles
- **WHEN** a member with no role assignments calls any organization-scoped route
- **THEN** the system responds `403 Forbidden`

#### Scenario: Revoked assignment
- **WHEN** a member's role assignment is soft-deleted
- **THEN** their next request requiring that role's permissions responds `403 Forbidden`

### Requirement: Route permissions
Organization-scoped routes SHALL require these permissions:

| Route | Permission |
|---|---|
| `GET /organization` | `organization:read` |
| `PATCH /organization` | `organization:update` |
| `DELETE /organization` | `organization:delete` |
| `GET /companies`, `GET /companies/:id` | `company:read` |
| `POST /companies` | `company:create` |
| `PATCH /companies/:id` | `company:update` |
| `DELETE /companies/:id` | `company:delete` |
| `GET /users`, `GET /users/:id` | `organization_user:read` |
| `DELETE /organization-users/:userID` | `organization_user:delete` |
| `POST /organization-invitations` | `organization_invitation:create` |
| `GET /organization-invitations` | `organization_invitation:read` |
| `DELETE /organization-invitations/:id` | `organization_invitation:delete` |
| `POST /roles` | `role:create` |
| `GET /roles`, `GET /roles/:id` | `role:read` |
| `PATCH /roles/:id` | `role:update` |
| `DELETE /roles/:id` | `role:delete` |
| `POST /organization-role-assignments` | `organization_role_assignment:create` |
| `GET /organization-role-assignments` | `organization_role_assignment:read` |
| `DELETE /organization-role-assignments/:id` | `organization_role_assignment:delete` |

#### Scenario: Each route enforces its permission
- **WHEN** a member lacking the listed permission calls the route
- **THEN** the system responds `403 Forbidden`

### Requirement: Roles
Members with role permissions SHALL be able to manage roles in their organization. A role SHALL have a name unique within its organization, a required level (`organization` or `company`) with no default, and a set of permissions whose levels all equal the role's level. A role's level SHALL NOT change after creation. A role with active assignments or pending invitations SHALL NOT be deletable. A deleted role's name SHALL be reusable. Removing a permission from a role SHALL soft-delete the grant with `deleted_by`, so the history of every role's permissions is kept.

#### Scenario: Create organization-level role
- **WHEN** a member with `role:create` creates role "Auditor" with level `organization` and `company:read`
- **THEN** the role is created in the caller's organization

#### Scenario: Level mismatch
- **WHEN** a role with level `company` is given an organization-level permission
- **THEN** the system responds `400 Bad Request`

#### Scenario: Missing level
- **WHEN** a role is created without a level
- **THEN** the system responds `400 Bad Request`

#### Scenario: Duplicate name
- **WHEN** a role is created with a name already used in the organization
- **THEN** the system responds `409 Conflict`

#### Scenario: Delete role in use
- **WHEN** a member deletes a role that has active assignments
- **THEN** the system responds `409 Conflict`

#### Scenario: Permission change takes effect immediately
- **WHEN** a permission is removed from a role
- **THEN** every member holding that role loses the permission on their next request

### Requirement: Role templates
The system SHALL define role templates in code. Provisioning an organization SHALL copy every template into that organization as ordinary, editable roles, recording `template_key` for reporting only. Later template changes SHALL NOT alter existing organizations' roles, and `template_key` SHALL NOT influence any access decision. This change SHALL ship:

- **Organization Administrator** (`org_admin`, organization level): every organization-level permission.
- **Organization Viewer** (`org_viewer`, organization level): every organization-level `:read` permission.

#### Scenario: Templates copied at provisioning
- **WHEN** an organization is provisioned
- **THEN** it has an "Organization Administrator" role and an "Organization Viewer" role with the template permissions

#### Scenario: Copied role is editable
- **WHEN** a member with `role:update` removes a permission from the copied "Organization Viewer"
- **THEN** the change applies to that organization only

### Requirement: Organization role assignments
Members with assignment permissions SHALL be able to assign an organization-level role from their organization to an active member, list assignments, and revoke them by soft delete. Re-granting a revoked role SHALL create a new assignment rather than restore the revoked one. Assigning a company-level role, a role from another organization, or a role to a non-member SHALL be rejected. Duplicate active assignments SHALL be rejected.

#### Scenario: Assign role
- **WHEN** a member with `organization_role_assignment:create` assigns "Organization Viewer" to an active member
- **THEN** the assignment is created with `created_by` set

#### Scenario: Assign company-level role at organization level
- **WHEN** the role's level is `company`
- **THEN** the system responds `400 Bad Request`

#### Scenario: Assign to non-member
- **WHEN** the target user is not an active member of the organization
- **THEN** the system responds `404 Not Found`

#### Scenario: Duplicate assignment
- **WHEN** the member already holds the role
- **THEN** the system responds `409 Conflict`

### Requirement: Company role assignment schema
The system SHALL persist company role assignments in a table separate from organization role assignments, with `organization_user_id`, `role_id`, and `company_id` all required. Company-scoped access SHALL never be inferred from organization role assignments. Enforcement of company-level permissions and endpoints for company role assignments are out of scope for this change.

#### Scenario: Company scope cannot be null
- **WHEN** a company role assignment is inserted without a `company_id`
- **THEN** the database rejects the insert
