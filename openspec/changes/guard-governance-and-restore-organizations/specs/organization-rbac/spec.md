## ADDED Requirements

### Requirement: Administrator continuity
An organization administrator SHALL be an active member holding every organization-level permission in the catalog. The system SHALL refuse, with `409 Conflict` and a `detail` stating why, any member removal, group member removal, group role removal, or role permission removal that would take the organization's number of administrators from one or more to zero. It SHALL evaluate this when a change is submitted and again when it is applied, and a held change that would cause this at apply SHALL end `failed`. Concurrent changes SHALL NOT together remove the last administrator. `template_key` SHALL NOT affect this rule.

#### Scenario: Removing the last administrator
- **WHEN** the only administrator removes themselves with `DELETE /organization-users/:userID`
- **THEN** the system responds `409` and the membership remains

#### Scenario: Removing the last group membership
- **WHEN** a member removes the only administrator from the group that grants their permissions
- **THEN** the system responds `409` and the group membership remains

#### Scenario: Removing the role from the group
- **WHEN** a member removes the administrator role from the only group holding it for any member
- **THEN** the system responds `409` and the attachment remains

#### Scenario: Narrowing the role
- **WHEN** a member removes `company:read` from the only role that makes anyone an administrator
- **THEN** the system responds `409` and the role is unchanged

#### Scenario: Another administrator remains
- **WHEN** two members are administrators and one is removed
- **THEN** the removal succeeds


#### Scenario: Administrator through a custom group
- **WHEN** a member holds every permission through a custom group, and the last member of Organization Administrators is removed
- **THEN** the removal succeeds

#### Scenario: Partial permissions
- **WHEN** a member holds every permission except one, and the only full administrator is removed
- **THEN** the system responds `409`

#### Scenario: No administrator today
- **WHEN** no member currently holds every permission and a member is removed
- **THEN** this rule does not refuse the removal

#### Scenario: Held removals applied in turn
- **WHEN** two held requests each remove one of two administrators, and the first is applied
- **THEN** approving the second ends it `failed` with its reason, and one administrator remains

#### Scenario: Concurrent removals
- **WHEN** two requests remove each of two administrators at the same time
- **THEN** one succeeds and the other responds `409`

#### Scenario: Unauthorized removal
- **WHEN** a member lacking `organization_user:delete` removes the last administrator
- **THEN** the system responds `403 Forbidden`

### Requirement: Caller access
The system SHALL expose `GET /me/access` to any active member of the organization selected by `X-Organization-ID`, returning that organization's ID and the caller's effective organization-level permissions, sorted. The result SHALL be computed by the same rule that enforces permissions. It SHALL be a complete single resource and SHALL NOT be paged. It SHALL be advisory for clients and SHALL grant nothing.

#### Scenario: Administrator
- **WHEN** an administrator calls `GET /me/access`
- **THEN** the response lists every organization-level permission

#### Scenario: Member with no group
- **WHEN** a member with no group calls `GET /me/access`
- **THEN** the system responds `200` with an empty `permissions` list

#### Scenario: Access differs per organization
- **WHEN** a person is an administrator of organization A and a viewer of organization B, and calls with B selected
- **THEN** only the viewer's permissions are returned

#### Scenario: Not a member
- **WHEN** a person calls with an organization they do not belong to
- **THEN** the system responds `403 Forbidden` and does not reveal whether it exists

#### Scenario: Removed member
- **WHEN** a member is removed and then calls `GET /me/access`
- **THEN** the system responds `403 Forbidden`

#### Scenario: Missing organization
- **WHEN** a person calls without `X-Organization-ID`
- **THEN** the system responds `400 Bad Request`

### Requirement: Permission catalog discovery
The system SHALL expose `GET /permissions` to members holding `role:read`, listing every permission in the catalog with its level, including permissions that cannot require approval. The catalog is defined in code and SHALL be the same for every organization.

#### Scenario: Full catalog
- **WHEN** a member with `role:read` lists every page of `GET /permissions`
- **THEN** every catalog permission appears once, including `company:read` and `approval_override:create`

#### Scenario: Without permission
- **WHEN** a member without `role:read` calls `GET /permissions`
- **THEN** the system responds `403 Forbidden`

#### Scenario: Not a member
- **WHEN** a person calls with an organization they do not belong to
- **THEN** the system responds `403 Forbidden`

## MODIFIED Requirements

### Requirement: Route permissions
Organization-scoped routes SHALL require these permissions. A gateable write SHALL require its permission before it is matched to approval policies. Approving, rejecting, and withdrawing require no permission and are authorized by approver eligibility and by being the requester, as the approval-workflows capability defines.

| Route | Permission |
|---|---|
| `GET /me/access` | None; active membership |
| `GET /permissions` | `role:read` |
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
| `GET /approval-requests/awaiting-me` | None; active membership, with results limited to requests the caller can approve |
| `GET /approval-requests/:id` | `approval_request:read`, or the requester, or a currently eligible approver |
| `POST /approval-requests/:id/override` | `approval_override:create` |

#### Scenario: Each route enforces its permission
- **WHEN** a member lacking the listed permission calls the route
- **THEN** the system responds `403 Forbidden`

#### Scenario: Role assignment routes removed
- **WHEN** a client calls `POST /organization-role-assignments`
- **THEN** the system responds `404 Not Found`
