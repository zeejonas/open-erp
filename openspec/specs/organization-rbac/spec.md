# organization-rbac

## Purpose

Zero-trust organization permissions granted only through groups, and roles copied from templates. Enforcing company-level permissions is out of scope.

## Requirements

### Requirement: Permission catalog
The system SHALL define permissions in code as `resource:action`, where action is one of `create`, `read`, `update`, `delete`, and each permission has a level of `organization` or `company`. Every permission in the catalog SHALL be enforced by at least one route. The catalog SHALL contain the following organization-level permissions:

- `organization:read`, `organization:update`, `organization:delete`
- `company:create`, `company:read`, `company:update`, `company:delete`
- `organization_user:read`, `organization_user:delete`
- `organization_invitation:create`, `organization_invitation:read`, `organization_invitation:delete`
- `role:create`, `role:read`, `role:update`, `role:delete`
- `group:create`, `group:read`, `group:update`, `group:delete`
- `group_member:create`, `group_member:read`, `group_member:delete`
- `group_role:create`, `group_role:delete`
- `group_company:create`, `group_company:delete`

#### Scenario: Unknown permission rejected
- **WHEN** a client creates or updates a role with a permission string not in the catalog
- **THEN** the system responds `400 Bad Request`

#### Scenario: Removed assignment permission rejected
- **WHEN** a client creates a role with `organization_role_assignment:create`
- **THEN** the system responds `400 Bad Request`

### Requirement: Zero-trust enforcement
A user SHALL hold an organization-level permission in an organization only if their active membership belongs, through an active group membership, to an active group in that organization that holds an active attachment to an active organization-level role whose permissions include it. Groups SHALL be the only path to a role. No permission SHALL be implied by a missing, null, or default value, by template origin, by company eligibility, or by the platform administrator flag.

#### Scenario: Granted permission
- **WHEN** a member of a group holding a role containing `company:read` calls `GET /companies`
- **THEN** the system responds `200 OK`

#### Scenario: Missing permission
- **WHEN** a member with no group whose roles contain `company:create` calls `POST /companies`
- **THEN** the system responds `403 Forbidden` and nothing is created

#### Scenario: Member with no groups
- **WHEN** a member who belongs to no groups calls any organization-scoped route
- **THEN** the system responds `403 Forbidden`

#### Scenario: Group with no roles
- **WHEN** a member belongs only to groups that hold no roles
- **THEN** organization-scoped routes respond `403 Forbidden`

#### Scenario: Deleted group
- **WHEN** a member's only granting group is soft-deleted
- **THEN** their next request requiring that group's permissions responds `403 Forbidden`

#### Scenario: Group in another organization
- **WHEN** a user belongs to a group in organization A that holds `company:read`, and calls `GET /companies` for organization B where they belong to no group
- **THEN** the system responds `403 Forbidden`

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
| `POST /groups` | `group:create` |
| `GET /groups`, `GET /groups/:groupID` | `group:read` |
| `PATCH /groups/:groupID` | `group:update` |
| `DELETE /groups/:groupID` | `group:delete` |
| `POST /groups/:groupID/members` | `group_member:create` |
| `GET /groups/:groupID/members` | `group_member:read` |
| `DELETE /groups/:groupID/members/:userID` | `group_member:delete` |
| `POST /groups/:groupID/roles` | `group_role:create` |
| `DELETE /groups/:groupID/roles/:roleID` | `group_role:delete` |
| `POST /groups/:groupID/companies` | `group_company:create` |
| `DELETE /groups/:groupID/companies/:companyID` | `group_company:delete` |

#### Scenario: Each route enforces its permission
- **WHEN** a member lacking the listed permission calls the route
- **THEN** the system responds `403 Forbidden`

#### Scenario: Role assignment routes removed
- **WHEN** a client calls `POST /organization-role-assignments`
- **THEN** the system responds `404 Not Found`

### Requirement: Roles
Members with role permissions SHALL be able to manage roles in their organization. A role SHALL have a name unique within its organization, a required level (`organization` or `company`) with no default, and a set of permissions whose levels all equal the role's level. A role's level SHALL NOT change after creation. A role attached to an active group SHALL NOT be deletable. A deleted role's name SHALL be reusable. Removing a permission from a role SHALL soft-delete the grant with `deleted_by`, so the history of every role's permissions is kept.

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
- **WHEN** a member deletes a role attached to an active group
- **THEN** the system responds `409 Conflict`

#### Scenario: Delete role held only by a deleted group
- **WHEN** a member deletes a role whose only attachment is to a soft-deleted group
- **THEN** the role is soft-deleted

#### Scenario: Permission change takes effect immediately
- **WHEN** a permission is removed from a role
- **THEN** every member of every group holding that role loses the permission on their next request

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
