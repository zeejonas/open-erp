## 1. Directory list

- [x] 1.1 Add platform directory DTOs and strict code/name/onboarded filters; test boolean parsing and undeclared, repeated, empty and malformed query rejection using existing list helpers.
- [x] 1.2 Register the platform-only GET collection route and implement Fluent filtering, updatedAt/ID ordering and pagination; test matching totals, literal wildcard characters, completion filtering, stable ties and pages past the end.

## 2. Organization detail

- [x] 2.1 Select the detail invitation with the existing `OrganizationInvitation.onboarding` helper, unchanged.
- [x] 2.2 Add detail metadata and accepted-history/missing-lineage/group diagnostics; test pending, expiry, revocation, accepted-without-completion, unavailable original group and permanent completion without read-side writes.
- [x] 2.3 Test missing/deleted/malformed organizations, unauthenticated/non-platform denial, absence of tokens/hashes and no implicit tenant access.

## 3. Contract and integration

- [x] 3.1 Annotate only the new routes/DTOs using the current OpenAPI APIs; assert bearer security, no tenant header, filter/page metadata and safe response schemas.
- [x] 3.2 Run focused directory/list/onboarding tests and OpenSpec validation; preserve shared auth/error/cache and export behavior if those changes have landed, without adding competing implementations.
