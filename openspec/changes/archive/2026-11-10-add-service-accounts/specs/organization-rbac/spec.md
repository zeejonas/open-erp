## ADDED Requirements

### Requirement: Service account permissions
The permission catalog SHALL include the organization-level permissions `service_account:create`, `service_account:read`, `service_account:update`, `service_account:delete`, and `service_account:disable`, enforced on these routes:

| Route | Permission |
|---|---|
| `POST /service-accounts` | `service_account:create` |
| `GET /service-accounts`, `GET /service-accounts/:id` | `service_account:read` |
| `PATCH /service-accounts/:id` | `service_account:update` |
| `POST /service-accounts/:id/disable` | `service_account:disable` |
| `DELETE /service-accounts/:id` | `service_account:delete` |

Service accounts SHALL receive permissions only through active group memberships, as people do, and the system SHALL NOT restrict which permissions a service account can be granted.

#### Scenario: Route enforces permission
- **WHEN** a member lacking `service_account:disable` calls `POST /service-accounts/:id/disable`
- **THEN** the system responds `403 Forbidden` and the account stays enabled

#### Scenario: Permissions through groups
- **WHEN** a service account is added to a group whose role grants `company:read`
- **THEN** the account can call `GET /companies`, and cannot call `POST /companies`

#### Scenario: Templates include the permissions
- **WHEN** an organization is provisioned
- **THEN** "Organization Administrator" holds every `service_account` permission and "Organization Viewer" holds `service_account:read`

### Requirement: Service accounts are not administrators
Administrator continuity SHALL count only people. A service account holding every organization-level permission SHALL NOT count as an administrator, so removing the last person administrator SHALL be refused even when such a service account exists.

#### Scenario: Bot cannot replace the last administrator
- **WHEN** a service account holds every organization-level permission and a member removes the only person administrator
- **THEN** the system responds `409 Conflict` and the membership remains
