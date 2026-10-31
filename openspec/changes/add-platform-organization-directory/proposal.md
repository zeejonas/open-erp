## Why

Platform operators can provision organizations but cannot discover or inspect them through the API. The discarded UI branch implemented this with a large SQL projection and an ambiguous onboarding status; the backend needs a smaller API-native directory.

## What Changes

- Add platform-only organization list and detail endpoints using Fluent and existing list conventions.
- Filter lists by literal case-insensitive `code`/`name` and boolean `onboarded`, ordered by `updatedAt` descending and ID ascending.
- Expose permanent onboarding completion separately from invitation lifecycle and explicit diagnostic reasons. Do not carry forward the unreleased combined `onboardingStatus` filter.
- Keep directory reads independent of provisioning/reissue writes, shared authentication/error middleware, and OpenAPI export tooling.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `platform-administration`: Organization directory authorization, metadata, paging, filters, and onboarding diagnostics.

## Impact

Platform routes, a directory DTO/filter, Fluent reads, focused database/API tests, and route-local OpenAPI annotations. No migration or new package. SOX/SOC: restricted operator visibility, no implicit tenant access, no secret disclosure, and no mutation of audit evidence during reads.

## Non-goals

Invitation delivery, tenant administration, new recovery semantics, combined invitation lifecycle filtering, UI behavior, global errors/cache rules, and spec export. The existing list-endpoints requirements are reused without editing them.
