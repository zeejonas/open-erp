## 1. Route

- [x] 1.1 Add a failing test: an eligible member without `approval_request:read` sees the request, and `metadata.total` counts it
- [x] 1.2 Expose an eligibility check from `ApprovalService` built on `eligibleTracks` with `approving: true`
- [x] 1.3 Register `GET /approval-requests/awaiting-me`, resolve eligible IDs, and page them through the existing list query
- [x] 1.4 Add a test that the constant path wins over `:requestID`, and that `GET /approval-requests/:id` still works

## 2. Eligibility and isolation

- [x] 2.1 Test later-stage, requester, already-approved, several-track, ended-request, and removed-membership scenarios
- [x] 2.2 Test paging, order, an empty result, and a 400 for an unknown parameter
- [x] 2.3 Test another organization, non-member 403, and missing credentials or header

## 3. Contract

- [x] 3.1 Add `.openAPI(...)` and `.problemResponses(...)` beside the route, and confirm it appears in `export-openapi` output
- [x] 3.2 Add the route to the `README.md` route table
- [x] 3.3 Add the route to the `organization-rbac` route permissions table
