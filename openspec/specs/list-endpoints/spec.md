# list-endpoints

## Purpose

Paging, strict query parameters, fixed order, and filters for every collection endpoint.

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
Every list endpoint SHALL accept `page` (an integer of 1 or greater, default 1), `per` (an integer from 1 to 100, default 25), and only the filters it declares. The system SHALL respond `400 Bad Request` with a reason naming the parameter when a value is out of range, not an integer, an empty filter, an unknown enum value, an undeclared parameter, or a repeated parameter. It SHALL NOT clamp, ignore, or otherwise reinterpret a parameter.

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

### Requirement: Fixed list order
Every list SHALL be ordered newest first by the listed model's `updatedAt`, or by `createdAt` when the model has no `updatedAt`, and then by `id`. No list endpoint SHALL accept a sort parameter.

| Endpoint | Order |
|---|---|
| `GET /companies` | company `updatedAt` |
| `GET /users` | user `updatedAt` |
| `GET /roles` | role `updatedAt` |
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

#### Scenario: Sort parameter rejected
- **WHEN** a member calls `GET /companies?sort=name`
- **THEN** the system responds `400` and names `sort`

### Requirement: List filters
Text filters SHALL match a case-insensitive substring, and `%`, `_`, and `\` in the value SHALL match literally. ID and enum filters SHALL match exactly. Filters SHALL combine with AND and SHALL apply within the caller's tenant scope. An ID from another organization SHALL match nothing rather than return an error. The filters for each endpoint SHALL be:

| Endpoint | Text filters | Exact filters |
|---|---|---|
| `GET /companies` | `code`, `name` | none |
| `GET /users` | `firstName`, `lastName`, `email` | `groupId`: active members of that active group |
| `GET /roles` | `name` | `level`: `organization` or `company` |
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
