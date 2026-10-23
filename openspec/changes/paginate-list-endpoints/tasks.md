## 1. Shared list helper

- [ ] 1.1 Add `ListPage` (validates `page` ≥ 1 and `per` 1–100, converts to `PageRequest` with defaults 1 and 25), the `ListFilters` protocol, and `NoFilters`
- [ ] 1.2 Add `Request.listParameters(_:)`, which rejects undeclared and repeated query keys with `400` naming the key, then validates and decodes `ListPage` and the filters
- [ ] 1.3 Add `QueryBuilder` helpers: newest-first by a timestamp then `id` (including a joined-model form), and `filter(_:contains:)` as escaped, schema-qualified `ILIKE` that skips `nil`
- [ ] 1.4 Set `app.fluent.pagination.pageSizeLimit = 100` in `configure.swift`
- [ ] 1.5 Add `ListTests` covering the contract once, on `GET /roles`: default and explicit pages, past the end, `per=101`, `page=0` and `page=abc`, an undeclared key, a repeated key, an empty filter, an unknown enum value, `sort=name`, stable order across `per=1` pages, and `403` without `role:read`

## 2. Organization lists

- [ ] 2.1 `GET /companies`: `code` and `name` filters, ordered by `updatedAt`. Test case-insensitive matching, literal `_`, a rename moving a company first, and a tenant-scoped `total`
- [ ] 2.2 `GET /roles`: `name` and `level` filters, ordered by `updatedAt`. Test the `level` filter
- [ ] 2.3 `GET /users`: `firstName`, `lastName`, `email`, and `groupId` filters, ordered by user `updatedAt`. Test combined filters, and that a removed group member or a deleted group doesn't match
- [ ] 2.4 `GET /groups`: `name`, `roleId`, and `companyId` filters, ordered by `updatedAt`, still eager-loading roles and companies. Test the company access-review case, a detached role not matching, and a role ID from another organization returning an empty page
- [ ] 2.5 `GET /groups/:groupID/members`: no filters, ordered by group membership `createdAt`
- [ ] 2.6 `GET /organization-invitations`: `email` and `groupId` filters over pending invitations, ordered by `createdAt`
- [ ] 2.7 `GET /me/organizations`: no filters, ordered by the joined organization's `updatedAt`

## 3. Existing tests and process

- [ ] 3.1 Switch every test that decodes a list array to decode `Page`, with no change to what it checks
- [ ] 3.2 Add the list-endpoints rule to `specs` in `openspec/config.yaml`

## 4. Finish

- [ ] 4.1 Run `swift build` and `swift test`, and confirm `openspec validate paginate-list-endpoints` passes
