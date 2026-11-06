## RENAMED Requirements

- FROM: `### Requirement: Fixed list order`
- TO: `### Requirement: Default list order`

## MODIFIED Requirements

### Requirement: Strict list parameters
Every list endpoint SHALL accept `page` (an integer of 1 or greater, default 1), `per` (an integer from 1 to 100, default 25), and only the filters and sort parameter it declares. The system SHALL respond `400 Bad Request` with a `bad_request` problem whose `detail` names the parameter when a value is out of range, not an integer, an empty filter, an unknown enum value, an undeclared parameter, or a repeated parameter. It SHALL NOT clamp, ignore, or otherwise reinterpret a parameter.

#### Scenario: Oversized page size
- **WHEN** a member calls `GET /roles?per=101`
- **THEN** the system responds `400` and names `per`

#### Scenario: Invalid page
- **WHEN** a member calls `GET /roles?page=0` or `GET /roles?page=abc`
- **THEN** the system responds `400` and names `page`

#### Scenario: Undeclared parameter
- **WHEN** a member calls `GET /roles?pageSize=50`
- **THEN** the system responds `400` and names `pageSize`

#### Scenario: Repeated parameter
- **WHEN** a member calls `GET /roles?name=AP&name=AR`
- **THEN** the system responds `400` and names `name`

#### Scenario: Empty filter
- **WHEN** a member calls `GET /roles?name=`
- **THEN** the system responds `400` and names `name`

#### Scenario: Unknown enum value
- **WHEN** a member calls `GET /roles?level=global`
- **THEN** the system responds `400` and names `level`

### Requirement: Default list order
Unless an endpoint declares a sort parameter and the request supplies it, every list backed by timestamped rows SHALL be ordered newest first by the listed model's `updatedAt`, or by `createdAt` when the model has no `updatedAt`, and then by `id` ascending. An endpoint that does not declare a sort parameter SHALL reject one as an undeclared parameter.

| Endpoint | Order |
|---|---|
| `GET /companies` | company `updatedAt` |
| `GET /users` | user `updatedAt` |
| `GET /roles` | role `updatedAt` |
| `GET /permissions` | `permission` ascending |
| `GET /groups` | group `updatedAt` |
| `GET /me/organizations` | organization `updatedAt` |
| `GET /groups/:groupID/members` | group membership `createdAt` |
| `GET /organization-invitations` | invitation `createdAt` |
| `GET /approval-policies` | policy `updatedAt` |
| `GET /approval-policies/:id/versions` | version `createdAt` |
| `GET /approval-requests` | request `updatedAt` |

#### Scenario: Recently edited first
- **WHEN** company "B" was created after company "A", "A" is then renamed, and a member calls `GET /companies`
- **THEN** "A" is listed before "B"

#### Scenario: Stable across pages
- **WHEN** a member reads every page of `GET /roles?per=1` while no role changes
- **THEN** each role appears exactly once

#### Scenario: Undeclared sort parameter rejected
- **WHEN** a member calls `GET /roles?sort=name`
- **THEN** the system responds `400` and names `sort`

## ADDED Requirements

### Requirement: Sortable list contract
An endpoint MAY declare a `sort` parameter by listing its sort fields, its default order, and its tie-break. A field SHALL be one the endpoint already returns to the caller. The value of `sort` SHALL be a comma-separated list of distinct declared fields in order of precedence, and a field SHALL sort ascending unless prefixed with `-` for descending. Field names SHALL match exactly, including case. The sort SHALL apply to the filtered, authorized result set before pagination, and the tie-break SHALL be applied last, so that the same unchanged rows always have one order. An empty value, empty term, undeclared field, or repeated field SHALL respond `400 Bad Request` with a `bad_request` problem whose `detail` names `sort`; for an undeclared or repeated field it SHALL also name the rejected term, and for an undeclared field it SHALL also name the allowed fields.

#### Scenario: Precedence and direction
- **WHEN** a member calls a sortable endpoint with `sort=name,-code`
- **THEN** rows are ordered by name ascending and, among equal names, by code descending

#### Scenario: Tie-break across pages
- **WHEN** rows have equal values in every requested field and a member reads every page with `per=1`
- **THEN** each row appears exactly once, in tie-break order

#### Scenario: Undeclared field
- **WHEN** a member calls `GET /companies?sort=organizationId`
- **THEN** the system responds `400`, and `detail` names `sort`, `organizationId`, and the allowed fields

#### Scenario: Field name differs in case
- **WHEN** a member calls `GET /companies?sort=Name`
- **THEN** the system responds `400`, and `detail` names `sort`, `Name`, and the allowed fields

#### Scenario: Repeated field
- **WHEN** a member calls `GET /companies?sort=name,-name`
- **THEN** the system responds `400`, and `detail` names `sort` and `name`

#### Scenario: Empty value or term
- **WHEN** a member calls `GET /companies?sort=` or `GET /companies?sort=name,`
- **THEN** the system responds `400` and names `sort`

#### Scenario: Repeated parameter
- **WHEN** a member calls `GET /companies?sort=name&sort=code`
- **THEN** the system responds `400` and names `sort`

#### Scenario: Published fields match accepted fields
- **WHEN** a client reads the published OpenAPI document for a sortable endpoint
- **THEN** the `sort` parameter documents exactly the fields the endpoint accepts

### Requirement: Company list sorting
`GET /companies` SHALL declare the sort fields `code`, `name`, and `updatedAt`, with default order `-updatedAt` and tie-break `id` ascending. `code` and `name` SHALL sort by the ICU root collation, independent of the database's default locale. Company `createdAt` and `updatedAt` SHALL NOT be null.

#### Scenario: Names sort in dictionary order
- **WHEN** a member with `company:read` has companies named "Zeta", "apple", "Éclair", "Banana", and "eagle" and calls `GET /companies?sort=name`
- **THEN** the order is "apple", "Banana", "eagle", "Éclair", "Zeta"

#### Scenario: Descending timestamp
- **WHEN** a member with `company:read` calls `GET /companies?sort=-updatedAt`
- **THEN** the most recently updated company is listed first

#### Scenario: Sort stays within the tenant
- **WHEN** a member of organization A calls `GET /companies?sort=name` and organization B has a company whose name sorts first
- **THEN** the response and its total contain only organization A's companies

#### Scenario: Read permission still required when sorting
- **WHEN** a member without `company:read` calls `GET /companies?sort=name`
- **THEN** the system responds `403 Forbidden`
