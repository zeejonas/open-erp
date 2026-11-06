## Context

The uncommitted implementation adds `sort` to `GET /companies` through a `sortFields` dictionary, `Request.sortableListParameters`, and `QueryBuilder.listOrder`. It works, and 96 tests pass, but the review found that its order depends on the database's locale and that its contract is spread across code, OpenAPI prose, and the spec.

`GET /companies` is the only sortable endpoint today. The design must make the next one a single declaration without adding machinery it doesn't need yet.

## Goals / Non-Goals

**Goals:** one declaration per sortable endpoint; a defined text order; all parameter validation in the request layer; published fields that cannot drift from accepted fields.

**Non-Goals:** see the proposal.

## Decisions

### One declaration per endpoint

A `ListSortOrder<Row>` value holds the field map, the default as a sort string (`"-updatedAt"`), and a tie-break closure that defaults to the base model's `id` ascending. A controller declares it once:

```swift
static let sort = ListSortOrder<Company>(
    fields: ["code": { $0.sort(\.$code, $1) }, "name": { $0.sort(\.$name, $1) }, "updatedAt": { $0.sort(\.$updatedAt, $1) }],
    default: "-updatedAt"
)
```

The default goes through the same parser as client input, so it can't diverge from a declared field or need a hand-written closure. An endpoint ordered by a joined model, such as `GET /me/organizations`, passes its own tie-break. [Fluent applies additional sorts in the order they were added](https://docs.vapor.codes/fluent/query/#sort), which gives precedence, and the tie-break is added last. FluentKit's `QueryBuilder.sort(_:_:)` accepts these key paths directly.

*Rejected:* a controller-level default closure (repeats `newestFirst`); a fixed base-model `id` tie-break (wrong for joined lists); string column names instead of closures (loses key-path checking); a protocol per sortable model (more types for the same data).

### Parse `sort` with the other parameters

`Request.listParameters(_:sort:)` checks declared keys, validates, and parses `sort` into typed terms. It returns those terms with the filters and page, and `QueryBuilder.sorted(by:)` only applies them and can't throw. Validation stays in [`Validatable`](https://docs.vapor.codes/basics/validation/) as it does for `page` and `per`, and it continues to reject a bare `?sort`, which probes showed returns `sort cannot be null`.

`detail` includes the rejected term and the allowed fields, consistent with the existing `Unknown parameter <name>` responses.

*Rejected:* parsing in the query builder (validation in two layers, and untestable without a query); a custom `Validator` (it reports through a fixed result shape, and we still need typed terms afterward).

### Column-level ICU collation for sortable text

`companies.code` and `companies.name` are declared as `TEXT COLLATE "und-x-icu"` using FluentSQL's raw `DatabaseSchema.DataType.sql(unsafeRaw:)`, with a constant string. PostgreSQL's docs describe [`und-x-icu` as the ICU root collation](https://www.postgresql.org/docs/current/collation.html), and libc collations depend on the operating system, which is why Alpine's `en_US.utf8` sorted by bytes.

A demo on `postgres:18-alpine` returned `apple, Apple, Banana, eagle, Éclair, Zeta`. `und-x-icu` is deterministic, so `(organization_id, code)` uniqueness still compares exact values, and `ILIKE` ran without error on the collated column; the existing filter tests must confirm matching behavior. Sorting with no change to the query keeps `sort(\.$name, ...)` as plain Fluent code.

*Rejected:* `ORDER BY lower(name)` (no accent ordering, and needs custom sort SQL per field); `COLLATE` per query (custom SQL at each sort, and an index on the column's collation wouldn't match); relying on the database default (the bug); `citext` (changes equality and needs an extension).

### Required timestamps and supporting indexes

`created_at` and `updated_at` become `.required` in `CreateCompany`. FluentKit 1.57.0 touches `.update` timestamps on create as well (`touchTimestamps(.create, .update)` in `Model+Concurrency.swift`, which the [model docs](https://docs.vapor.codes/fluent/model/#timestamp) don't state, so a test pins it), so normal writes are unaffected, and no raw company inserts exist. The pre-release policy in `openspec/config.yaml` allows this in-place edit.

`CreateCompany` also adds `(organization_id, name)` and `(organization_id, updated_at)` through SQLKit's `create(index:)`, as `createActiveUniqueIndex` already does. `(organization_id, code)` is covered by the unique constraint. In the demo, the name index served a tenant-scoped page by index scan with incremental sort on `id`.

*Rejected:* `NULLS LAST` in the sort (handles a state that shouldn't exist); partial `deleted_at IS NULL` indexes (Fluent's soft-delete filter also allows future deletion dates, so the predicate may not match).

### Publish fields from the declaration

`ListSortOrder` derives two values used by the route's `.openAPI(...)`: a query parameter with a pattern built from its sorted fields, using VaporToOpenAPI's [custom parameter schema](https://github.com/dankinsoid/VaporToOpenAPI), and a description sentence. `APIDocumentationTests` asserts that the published pattern contains exactly the declared fields. A pattern cannot express "distinct", so the description states it.

*Rejected:* `.type(ListSort.self)` with hand-written prose (the drift this fixes); a schema enum (a comma-separated list isn't one value).

## Risks / Trade-offs

- [A production PostgreSQL lacks ICU] → The create migration fails on first run, which is visible and safe. Confirm ICU on the production database before release.
- [Existing development databases keep the old schema] → Reset them. This is the documented pre-release path, and it wipes local data.
- [ICU library upgrades can change sort order and require reindexing] → PostgreSQL reports collation version mismatches; handle them in upgrade runbooks.
- [VaporToOpenAPI's literal parameter form may not carry the pattern through `all(of:)`] → Task 3.1 proves it first; if it doesn't, fall back to a generated description and test against that.

## Migration Plan

Edit `CreateCompany` in place and reset development databases. No production database exists under the pre-release policy. Rollback is reverting the change and resetting again.

## Open Questions

None.
