## ADDED Requirements

### Requirement: Permission catalog list
`GET /permissions` SHALL use the standard paged envelope and strict parameters, and SHALL accept a `level` filter of `organization` or `company`. Its rows are defined in code and have no timestamp, so it SHALL order by `permission` ascending.

#### Scenario: Filter by level
- **WHEN** a member with `role:read` calls `GET /permissions?level=organization`
- **THEN** only organization-level permissions are returned, in `permission` order, with `total` counting them

#### Scenario: Undeclared parameter
- **WHEN** a member calls `GET /permissions?name=x`
- **THEN** the system responds `400` and names `name`

#### Scenario: Read permission still required
- **WHEN** a member without `role:read` calls `GET /permissions?level=organization`
- **THEN** the system responds `403 Forbidden`

#### Scenario: Tenant selection still required
- **WHEN** a person who is not a member of the selected organization calls `GET /permissions`
- **THEN** the system responds `403 Forbidden`
