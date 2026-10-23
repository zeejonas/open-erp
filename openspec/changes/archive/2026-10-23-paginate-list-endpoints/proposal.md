## Why

Every list endpoint returns an unbounded array in no defined order. Responses grow with the tenant, the order can change between calls, and an auditor reviewing access has to download everything and join it client-side. Before release is the cheapest time to set one list contract for every current and future endpoint.

## What Changes

- **BREAKING**: Every endpoint that returns a collection responds with a page: `{ "items": [...], "metadata": { "page", "per", "total" } }`. This covers `GET /companies`, `/users`, `/roles`, `/groups`, `/groups/:groupID/members`, `/organization-invitations`, and `/me/organizations`.
- Every list endpoint accepts `page` (1 or greater, default 1) and `per` (1 to 100, default 25). Values out of range get a `400`, never a silently adjusted page.
- A query parameter the endpoint doesn't declare, or one that's repeated, gets a `400`.
- One fixed order: newest first by `updatedAt` when the model has one, otherwise by `createdAt`, with `id` as the tiebreaker. Clients can't choose a sort.
- Per-endpoint filters. Text filters match a case-insensitive substring. ID and enum filters match exactly.
  - `/companies`: `code`, `name`
  - `/users`: `firstName`, `lastName`, `email`, `groupId`
  - `/roles`: `name`, `level`
  - `/groups`: `name`, `roleId`, `companyId`
  - `/organization-invitations`: `email`, `groupId`
  - `/groups/:groupID/members` and `/me/organizations`: none
- Future endpoints that return a collection must follow the same contract. The project's OpenSpec config gains a spec rule saying so.

## Non-goals

- Client-chosen sorting.
- Cursor or keyset pagination. A future high-volume or audit table decides this in its own design.
- Full-text search, a combined `q` parameter, and new indexes for substring search.
- Listing soft-deleted rows.
- Changes to single-resource endpoints or to permissions.

## SOX / SOC Impact

- **Access control**: No new permissions, and each list keeps its existing read permission. Filters run inside the existing tenant scope, so an ID from another organization matches nothing, and `total` counts only the caller's organization.
- **Access reviews**: `groups?roleId=`, `groups?companyId=`, and `users?groupId=` answer "who can do X" and "who can act at company Y" directly, without client-side joins.
- **Completeness of evidence**: `total` lets an export check that it collected every row. Ordering by `updatedAt` can shift rows between pages while records are edited, so exports used as evidence must not depend on page order.
- **Data exposure**: Name and email filters put personal data in URLs. Vapor's route logging records only the path, but proxies and load balancers usually log full URLs.
- **Segregation of duties**: Unchanged.

## Capabilities

### New Capabilities
- `list-endpoints`: The list contract for every collection endpoint (page shape, `page` and `per` limits, strict parameters, fixed timestamp order, and filter semantics), plus each current endpoint's filters.

### Modified Capabilities
None. Existing specs say which collections can be listed and which permission each needs. They don't describe the response shape, so their requirements don't change.

## Impact

- **Code**: A shared list helper (validation, key checks, ordering, pagination), one filter type per endpoint, and the seven list handlers. `configure.swift` sets Fluent's page size limit as a backstop.
- **API**: Every list response changes from an array to a page.
- **Tests**: Existing tests that decode list arrays switch to pages. New tests cover the contract once and each endpoint's filters.
- **Process**: `openspec/config.yaml` gains a spec rule for list endpoints.
