## Context

`eligibleTracks` in `Approval/ApprovalService.swift` decides who can approve: not the requester, in an active group named by a slot of a pending track's current stage, and no earlier approval in that track. Stage slots live in the policy version's `definition` JSON, so eligibility cannot be expressed as a plain Fluent filter.

## Goals / Non-Goals

**Goals:** one list per caller and organization, with correct `total`, standard paging, and the same eligibility as the approve action.

**Non-Goals:** the items listed under Non-goals in the proposal, and optimizing for organizations with very large pending queues.

## Decisions

**A dedicated route, not a filter.** Each route keeps one authorization rule. A filter on `GET /approval-requests` would make its permission depend on a query value. The constant path must take priority over `:requestID`; [Vapor routing](https://docs.vapor.codes/basics/routing/) registers both, and a test proves the result.

**Reuse `eligibleTracks` with `approving: true`.** A member who has already approved a track has nothing left to do there, so that track does not count. They may still reject, and `GET /approval-requests/:id` still works for them.

**Resolve IDs in Swift, then page with Fluent.** Load the organization's pending requests, keep those with at least one eligible track, then run the normal query with a [subset filter](https://docs.vapor.codes/fluent/query/#subset-filter) on those IDs and [`paginate`](https://docs.vapor.codes/fluent/query/#paginate). `total`, ordering, and DTO mapping stay identical to the existing list. Work grows with the organization's pending requests, not its full history.

**Order by request `updatedAt`, newest first**, with the ID tie-breaker `newestFirst` already applies, as `GET /approval-requests` does.

**Paging parameters only.** `ListFilters` with no keys, so any other parameter returns 400 under the strict list rules.

**The behavior lives in `approval-workflows`, with a row in `organization-rbac`.** The route table lists read routes individually, including `GET /approval-requests/:id`, so this route gets its own row. `list-endpoints` already applies to collection endpoints added later.

### Rejected alternatives

- `awaitingMe=true` filter on the existing list: conditional authorization on one route.
- SQL over the `definition` JSON: duplicates the eligibility rule, and the two could drift.
- Group IDs on `/me` so clients compute eligibility: moves a segregation-of-duties rule into every client.
- Filtering a page in memory after `paginate`: wrong `total` and short pages.

## Risks / Trade-offs

- A large pending queue makes this slower, since eligibility runs per request. → Bounded by pending requests; add indexes or a SQL form only if measured.
- A request can leave the list between read and approve. → The approve action re-checks eligibility and returns 403 or 409 as it does today.

## Migration Plan

Additive route with no migration. Rollback removes the route.

## Open Questions

None.
