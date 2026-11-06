# list-endpoints

## Purpose

Paging, strict query parameters, stable ordering, sorting, and filters for collection endpoints.

## Requirements

### Requirement: Paged list responses
Every endpoint that returns a collection SHALL respond with `{ "items": [...], "metadata": { "page", "per", "total" } }`, where `total` counts every matching row in the caller's scope. This SHALL apply to `GET /companies`, `/users`, `/roles`, `/groups`, `/groups/:groupID/members`, `/organization-invitations`, `/me/organizations`, `/approval-policies`, `/approval-policies/:id/versions`, `/approval-requests`, and every collection endpoint added later. A page past the last one SHALL return `200` with no items and the real `total`.

#### Scenario: First page by default
- **WHEN** a member with `role:read` calls `GET /roles` in an organization with 30 roles and sends no paging parameters
- **THEN** the response holds 25 items with `metadata` of `page` 1, `per` 25, and `total` 30

#### Scenario: Requested page
- **WHEN** the member calls `GET /roles?page=2&per=10` in that organization
- **THEN** the response holds roles 11 through 20 in list order, with `page` 2, `per` 10, and `total` 30

#### Scenario: Page past the end
- **WHEN** the member calls `GET /roles?page=99`
- **THEN** the system responds `200` with no items and `total` 30

#### Scenario: Total is tenant-scoped
- **WHEN** organization A has 3 companies, organization B has 5, and a member of A with `company:read` calls `GET /companies`
- **THEN** `total` is 3 and no item belongs to organization B

#### Scenario: Read permission still required
- **WHEN** a member without `role:read` calls `GET /roles?page=1`
- **THEN** the system responds `403 Forbidden`

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

### Requirement: List filters
Text filters SHALL match a case-insensitive substring, and `%`, `_`, and `\` in the value SHALL match literally. ID and enum filters SHALL match exactly. Filters SHALL combine with AND and SHALL apply within the caller's tenant scope. An ID from another organization SHALL match nothing rather than return an error. The filters for each endpoint SHALL be:

| Endpoint | Text filters | Exact filters |
|---|---|---|
| `GET /companies` | `code`, `name` | none |
| `GET /users` | `firstName`, `lastName`, `email` | `groupId`: active members of that active group |
| `GET /roles` | `name` | `level`: `organization` or `company` |
| `GET /permissions` | none | `level`: `organization` or `company` |
| `GET /groups` | `name` | `roleId`: groups with that role attached; `companyId`: groups eligible at that company |
| `GET /organization-invitations` | `email` | `groupId` |
| `GET /groups/:groupID/members` | none | none |
| `GET /me/organizations` | none | none |
| `GET /approval-policies` | `name` | `permission`: a gateable permission; `groupId`: policies with a slot naming that group; `companyId`: policies scoped to that company |
| `GET /approval-policies/:id/versions` | none | none |
| `GET /approval-requests` | none | `status`: `pending`, `applied`, `rejected`, `withdrawn`, or `failed`; `permission`: a gateable permission; `requestedBy`: a user ID |

#### Scenario: Case-insensitive substring
- **WHEN** companies "Acme Corp" and "Globex" exist and a member calls `GET /companies?name=acme`
- **THEN** only "Acme Corp" is returned and `total` is 1

#### Scenario: Wildcards match literally
- **WHEN** companies "A_B" and "AXB" exist and a member calls `GET /companies?name=A_B`
- **THEN** only "A_B" is returned

#### Scenario: Filters combine
- **WHEN** a member calls `GET /users?lastName=smith&groupId=<AP Clerks>`
- **THEN** only active members of "AP Clerks" whose last name contains "smith" are returned

#### Scenario: Access review by company
- **WHEN** groups "AP Clerks" and "Viewers" exist, only "AP Clerks" is eligible at company X, and a member with `group:read` calls `GET /groups?companyId=<X>`
- **THEN** only "AP Clerks" is returned

#### Scenario: Removed links do not match
- **WHEN** role R was detached from group G and a member calls `GET /groups?roleId=<R>`
- **THEN** G is not returned

#### Scenario: Removed group members do not match
- **WHEN** a user was removed from "AP Clerks" and a member calls `GET /users?groupId=<AP Clerks>`
- **THEN** that user is not returned

#### Scenario: ID from another organization
- **WHEN** a member of organization B calls `GET /groups?roleId=<a role in organization A>`
- **THEN** the system responds `200` with no items and `total` 0

#### Scenario: Malformed ID
- **WHEN** a member calls `GET /groups?roleId=abc`
- **THEN** the system responds `400` and names `roleId`

#### Scenario: Policies routing to a group
- **WHEN** "Role changes" names group "Security" in a slot, "Company edits" does not, and a member with `approval_policy:read` calls `GET /approval-policies?groupId=<Security>`
- **THEN** only "Role changes" is returned

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
