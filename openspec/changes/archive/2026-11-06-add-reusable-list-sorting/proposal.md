## Why

The uncommitted multi-field sort on `GET /companies` works, but its review found problems that would spread to every endpoint that copies it. `sort=name` returns `Banana, Zeta, apple` on the project's `postgres:18-alpine` database, the allowed fields are hand-copied in three places, and the id tie-break the requirement depends on appears untested. The feature also skipped the OpenSpec workflow, so this change records it and fixes it before it is committed.

## What Changes

- Add a generic sort contract to `list-endpoints`: the grammar, error rules, deterministic tie-break, and what an endpoint must declare.
- Give each endpoint one declaration of its sort fields, default order, and tie-break. Parsing, documentation, and error messages all derive from it.
- Parse `sort` with the other request parameters instead of inside a query builder extension.
- Sort company `code` and `name` in a defined, database-independent order using the ICU root collation.
- Make company `created_at` and `updated_at` required, so sorting never meets a `NULL` timestamp.
- Index the company sort columns within an organization.
- Name the rejected term and the allowed fields in the `400` for an invalid sort.
- Publish the allowed fields in OpenAPI from the endpoint's declaration, and test that they match.
- Cover the id tie-break, each field, and both directions with tests.
- **BREAKING (pre-release):** the create migration for `companies` is edited in place, so existing development databases must be reset.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `list-endpoints`: replace the fixed-order rule with a default order, add the generic sort contract, and declare `GET /companies` as the first sortable endpoint.

## Impact

- **Code:** `List/ListQuery.swift`, `Controllers/CompanyController.swift`, `Migrations/CreateCompany.swift`.
- **Tests:** `ListTests.swift`, `APIDocumentationTests.swift`.
- **API:** `GET /companies` gains `sort`. Other list endpoints still reject it. The published OpenAPI document changes.
- **Database:** requires a PostgreSQL build with ICU. The project's `postgres:18-alpine` image has it; any production database must be confirmed before release.

## SOX/SOC impact

- **Access control:** unchanged. `company:read` and tenant scope apply before sorting, and only fields already returned to the caller can be sorted, so ordering reveals nothing new.
- **Audit trail:** no writes are added. Required timestamps strengthen the record of when a company was created and last changed.
- **Segregation of duties:** unchanged.

## Non-goals

- Adding `sort` to any endpoint other than `GET /companies`.
- Keyset pagination, or stable results while rows change between page reads.
- Case-insensitive or accent-insensitive equality; filters and the unique company code rule keep their current behavior.
- Per-language or per-tenant collation.
