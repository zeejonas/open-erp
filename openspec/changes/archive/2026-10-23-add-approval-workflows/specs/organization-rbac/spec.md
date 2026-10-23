## MODIFIED Requirements

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
- `approval_policy:create`, `approval_policy:read`, `approval_policy:update`, `approval_policy:delete`
- `approval_request:read`
- `approval_override:create`

#### Scenario: Unknown permission rejected
- **WHEN** a client creates or updates a role with a permission string not in the catalog
- **THEN** the system responds `400 Bad Request`

#### Scenario: Removed assignment permission rejected
- **WHEN** a client creates a role with `organization_role_assignment:create`
- **THEN** the system responds `400 Bad Request`

#### Scenario: Templates include approval permissions
- **WHEN** an organization is provisioned
- **THEN** "Organization Administrator" holds every approval permission including `approval_override:create`, and "Organization Viewer" holds `approval_policy:read` and `approval_request:read`

### Requirement: Route permissions
Organization-scoped routes SHALL require these permissions. A gateable write SHALL require its permission before it is matched to approval policies. Approving, rejecting, and withdrawing require no permission and are authorized by approver eligibility and by being the requester, as the approval-workflows capability defines.

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
| `GET /approval-catalog` | `approval_policy:read` |
| `POST /approval-policies` | `approval_policy:create` |
| `GET /approval-policies`, `GET /approval-policies/:id`, `GET /approval-policies/:id/versions` | `approval_policy:read` |
| `PATCH /approval-policies/:id` | `approval_policy:update` |
| `DELETE /approval-policies/:id` | `approval_policy:delete` |
| `GET /approval-requests` | `approval_request:read` |
| `GET /approval-requests/:id` | `approval_request:read`, or the requester, or a currently eligible approver |
| `POST /approval-requests/:id/override` | `approval_override:create` |

#### Scenario: Each route enforces its permission
- **WHEN** a member lacking the listed permission calls the route
- **THEN** the system responds `403 Forbidden`

#### Scenario: Role assignment routes removed
- **WHEN** a client calls `POST /organization-role-assignments`
- **THEN** the system responds `404 Not Found`
