## Context

Seven handlers build a tenant-scoped Fluent query, call `.all()`, and map the results to DTOs. None of them sorts, none accepts query parameters, and each returns an array. `GET /users` and `GET /groups/:groupID/members` join `organization_users`, `GET /me/organizations` joins `organizations`, and `GET /roles` and `GET /groups` eager-load children. All IDs are random `gen_random_uuid()` values. Every model has `createdAt`. Every listed model except `GroupMember` and `OrganizationInvitation` also has `updatedAt`. Fluent sets `updatedAt` on create as well as on update (`touchTimestamps(.create, .update)` in FluentKit), so it is never null for these rows. The project is pre-release, and `add-user-groups` is already in the code.

## Goals / Non-Goals

**Goals:**
- One small shared helper, so a new list endpoint is a filter type plus about five lines of handler code.
- Every parameter error is a `400` that names the parameter.
- No new tables, columns, or indexes.

**Non-Goals:**
- Client-chosen sorting, cursor pagination, full-text search, and listing soft-deleted rows.
- Automated discovery of list routes. The spec and the config rule are the enforcement.

## Decisions

### 1. Fluent's `Page` is the response
Handlers return `Page<DTO>` from `paginate(_:)`, which runs `count()` and then `range(...).all()` and returns `items` and `metadata` (https://docs.vapor.codes/fluent/query/#paginate). Fluent conforms `Page` to `Content`, and `Page.map` turns models into DTOs. Eager loading and joins work with `paginate`, and FluentKit's pagination tests cover `.with`.

The handler passes an explicit `PageRequest(page:per:)` rather than calling `paginate(for:)`. That's because `paginate(for:)` defaults `per` to 10 and accepts any size. `configure.swift` sets `app.fluent.pagination.pageSizeLimit = 100` as a backstop for a handler that skips validation. Fluent clamps at that limit rather than rejecting, so the limit is only a backstop.

*Rejected:* a custom page DTO (duplicates `Page`); `paginate(for:)` (wrong default, no rejection).

### 2. Validation, then strict keys, then decode
`ListPage` is a `Decodable` and `Validatable` type holding `page` and `per`. It validates `.range(1...)` and `.range(1...100)` with `required: false` and converts to a `PageRequest` with defaults 1 and 25. Each endpoint declares a filter type:

```swift
protocol ListFilters: Decodable, Validatable {
    static var keys: Set<String> { get }
}

struct RoleListFilters: ListFilters {
    static let keys: Set<String> = ["name", "level"]
    var name: String?
    var level: RoleLevel?

    static func validations(_ validations: inout Validations) {
        validations.add("name", as: String.self, is: !.empty, required: false)
        validations.add("level", as: String.self, is: .case(of: RoleLevel.self), required: false)
    }
}
```

`req.listParameters(RoleListFilters.self)` returns the filters and a `PageRequest`. It works in four steps:
1. Read the parameter names from the raw query string with `URLComponents`.
2. Reject any name outside `keys ∪ {page, per}`, or any repeated name, with `400`.
3. Run `validate(query:)` for `ListPage` and for the filter type (https://docs.vapor.codes/basics/validation/#validating-request-query).
4. Decode both types with `req.query.decode`.

Enum filters use Vapor's `.case(of:)` validator, whose failure message lists the allowed values. Endpoints without filters use `NoFilters`, where `keys` is empty.

The validation API is used because Codable errors are hard to read and stop at the first failure (https://docs.vapor.codes/basics/validation/#human-readable-errors). `keys` is listed explicitly because `Validations` keeps its entries internal, so the set of allowed keys can't be read from it. A key in `keys` with no matching property is silently ignored, so each filter's test covers both the key and the property.

*Rejected:* decoding with an unknown-key-rejecting decoder (Vapor's URL decoder has no strict mode); deriving keys from explicit `CodingKeys` (more boilerplate per type for the same guarantee).

### 3. Order is a fixed timestamp, then `id`
A helper on `QueryBuilder` sorts the given timestamp `.descending` and then `id` (https://docs.vapor.codes/fluent/query/#sort). The sort is fixed per endpoint, as in the spec table. `/me/organizations` sorts on the joined `Organization` (`.sort(Organization.self, …)`, https://docs.vapor.codes/fluent/query/#join). Because IDs are random, `id` only breaks ties and doesn't imply age.

*Rejected:* `createdAt` everywhere (more stable, but the product wants recent activity first); client sort fields (a mapping per endpoint, which this change avoids).

### 4. Substring filters use escaped `ILIKE`
Fluent's contains operator (`~~`) compiles to `LIKE '%value%'` without escaping (`SQLQueryConverter` in FluentSQL). On Postgres that is case-sensitive, and `_` or `%` in the value act as wildcards. Instead, a `QueryBuilder.filter(_:contains:)` helper does the following:
- Escapes `\`, `%`, and `_`.
- Wraps the value in `%…%`.
- Adds `.filter(.sql(...))` with a column qualified by the model's schema and `ILIKE`.

Qualifying the column avoids ambiguity on joined queries. Raw SQL filters already appear in the code (`User.find(email:)`). Passing `nil` adds no filter, so handlers can call it once per text filter without branching.

*Rejected:* `LOWER(col) LIKE LOWER(value)` (same raw SQL, more of it); the `pg_trgm` extension (a new dependency for small tables).

### 5. Relationship filters join active links
- `groups?roleId` joins `group_roles`, and `groups?companyId` joins `group_companies`.
- `users?groupId` joins `group_members` on the existing `organization_users` join, and also requires the group to be active.
- `organization-invitations?groupId` filters the invitation's `group_id` column directly.

Each join filters `deleted_at IS NULL`, because Fluent excludes soft-deleted rows only on the base model. Active-unique indexes allow at most one active link per pair, so these joins can't duplicate rows or inflate `total`. An ID from another organization reaches no row through the tenant-scoped base query, so the result is empty.

*Rejected:* `400` or `404` for a foreign ID (an extra lookup that reveals whether the ID exists); subqueries (Fluent has no subquery builder, so they'd need raw SQL).

### 6. Enforcing the rule for future endpoints
The `list-endpoints` spec requires every collection endpoint to follow this contract. `openspec/config.yaml` gains a `specs` rule: "Collection endpoints follow the list-endpoints spec: declare filters and the order timestamp." The shared helper makes the compliant handler the shortest one to write.

*Rejected:* a test that walks every route (needs fixtures for every permission and every allowed single-resource endpoint, which is bloat at the current size).

## Risks / Trade-offs

- [Rows move between pages when `updatedAt` changes during paging] → Documented in the proposal. Evidence exports must not depend on page order. Revisit with keyset pagination for high-volume tables.
- [Two queries per page, so `total` can drift under concurrent writes] → Accepted. This is how Fluent's pagination works.
- [Substring scans and `updated_at` sorts have no indexes] → The tables are small configuration data. Add indexes when a table needs them, under the pre-release migration policy.
- [Personal data in filter URLs] → Vapor logs only the path. Deployments should treat proxy access logs as containing personal data.
- [`keys` and the filter properties can drift] → Each filter has a test, so a key whose property is missing shows up as a filter that does nothing.
- [Every list response changes shape] → Pre-release, with no external clients.

## Migration Plan

No schema change. Deploy the new build. Rollback is redeploying the previous build.

## Open Questions

None.
