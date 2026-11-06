## 1. Restore the spec baseline

- [x] 1.1 Restore `openspec/specs/list-endpoints/spec.md` to `HEAD`, because this change's delta now carries that uncommitted edit and applies at archive
- [x] 1.2 Run `openspec validate add-reusable-list-sorting --strict`

## 2. Sort contract and parsing

- [x] 2.1 Add `ListSortOrder<Row>` with fields, default, and tie-break, replacing `ListSortField` and the `defaultOrder` closure
- [x] 2.2 Parse `sort` into typed terms in `Request.listParameters(_:sort:)`, replacing `sortableListParameters`, with `detail` naming `sort`, the rejected term, and the allowed fields
- [x] 2.3 Replace `listOrder` with a non-throwing `QueryBuilder.sorted(by:)` that applies terms and then the tie-break
- [x] 2.4 Declare the order on `CompanyController` and use it in `index`
- [x] 2.5 Test precedence, each field in both directions, the default order, and rejection `detail` for undeclared, wrong-case, repeated, empty, and bare `sort`
- [x] 2.6 Test the tie-break by paging `sort=name&per=1` over equal names and asserting `id` order, then confirm the test fails when the tie-break is removed

## 3. OpenAPI

- [x] 3.1 Derive the `sort` parameter pattern and description from `ListSortOrder`, and confirm the pattern reaches the published document
- [x] 3.2 Use them in the `GET /companies` route in place of the hand-written field list
- [x] 3.3 Assert in `APIDocumentationTests` that the published fields exactly match the declaration

## 4. Schema

- [x] 4.1 Declare `companies.code` and `companies.name` with `TEXT COLLATE "und-x-icu"`
- [x] 4.2 Test the spec's dictionary-order scenario for `sort=name`, and confirm existing filter tests still pass
- [x] 4.3 Make company `created_at` and `updated_at` required, and test that `sort=-updatedAt` lists the most recently updated company first
- [x] 4.4 Add `(organization_id, name)` and `(organization_id, updated_at)` indexes, and confirm with `EXPLAIN` on a seeded database that a tenant-scoped sort uses them

## 5. Authorization and isolation

- [x] 5.1 Keep tests that `sort` respects tenant scope and totals, and that a member without `company:read` gets `403`

## 6. Verify

- [x] 6.1 Run the full suite against a dedicated database by setting `DATABASE_*`, never the running development database, because `withApp` reverts all migrations
- [x] 6.2 Run `openspec validate add-reusable-list-sorting --strict`
