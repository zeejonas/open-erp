## Context

`main` has platform provisioning and reissue but no list/detail route. `feat/add-small-ui` derived a combined onboarding status through a SQL CASE/LATERAL projection. The permanent `Organization.onboardedAt` and invitation history already exist. Use the current backend as the baseline, not the discarded UI implementation.

## Goals / Non-Goals

**Goals:** Discover active organizations with correct database paging; inspect onboarding without conflating completion, invitation state, and inconsistent evidence; preserve platform/tenant separation.

**Non-Goals:** Reconstruct the old combined status filter; change acceptance/reissue eligibility or locking; persist derived status; introduce a new error system, cache middleware, or export generator.

## Decisions

1. **Use the existing Fluent list path.** Add a `PlatformOrganizationListFilters` value and call `listParameters`, existing literal text filters, `newestFirst(\.$updatedAt)`, and `paginate`. Apply `onboarded` as a null/non-null field filter before count/pagination. Decode it with Vapor's standard query boolean parsing (case-insensitive `true`/`false`, plus `1`/`0`/`on`); reject other values and repeated/undeclared parameters. [Fluent queries](https://docs.vapor.codes/fluent/query/).
2. **Keep the list cheap.** List items contain organization ID, code, name, creation/update timestamps and actor IDs, and `onboardedAt`. They do not query invitation history. `onboardingStatus` is intentionally not a supported filter. Stable completion filtering serves the initial directory without derived SQL or an N+1 history lookup.
3. **Detail separates facts.** Return the organization metadata plus `onboardingInvitation` (nullable) and `onboardingIssue` (nullable). Invitation metadata includes ID, recipient name/email, group ID, expiry, acceptance time, revocation time, and creator ID, never a token/hash. Pick a non-deleted onboarding invitation first, otherwise the newest revoked invitation by `createdAt` descending then ID descending. Reuse the existing `OrganizationInvitation.onboarding` helper unchanged; reissue's locked recovery path depends on it. [Fluent first/filter/sort](https://docs.vapor.codes/fluent/query/).
4. **Report exceptional lineage explicitly.** For an organization without `onboardedAt`, issue precedence is `accepted_without_completion` if any onboarding history is accepted (including deleted history), `missing_onboarding_invitation` if none exists, then `original_group_unavailable` if the selected invitation lacks an active same-organization group. Otherwise issue is null. Completed organizations have no recovery diagnostic. Invitation expiry/revocation remain separate factual fields; no `unavailable` catch-all. No reads repair history or promise reissue will succeed after a later concurrent change.
5. **Reuse existing authorization and errors.** Register on `AuthMiddleware` + `PlatformAdminMiddleware`. Use ordinary `Abort` status errors, which automatically receive whichever global error policy is installed. Add only route-local OpenAPI annotations. [Vapor routing](https://docs.vapor.codes/basics/routing/), [Vapor errors](https://docs.vapor.codes/basics/errors/).

Rejected alternatives:
- CASE/LATERAL projections: unnecessary for a completion-only filter and obscure ordinary list behavior.
- Fetch all organizations or filter after pagination: unbounded memory or incorrect totals/pages.
- Persist an onboarding status: duplicates domain facts and adds synchronization paths.
- Treat accepted history as completion: would hide an audit inconsistency and alter recovery behavior.

## Risks / Trade-offs

- [Narrower filters than the UI branch] → Explicitly publish only code/name/onboarded; invitation lifecycle filtering is deferred rather than partially implemented.
- [Concurrent reissue/acceptance during a detail read] → Diagnostic metadata is advisory; existing locked transactional writes remain authoritative. Do not add read locks to directory traffic.
- [Platform metadata contains recipient PII] → Enforce platform authorization before lookup; expose no tenant content or credentials.

## Migration Plan

No schema migration. Add endpoints and tests; rollback removes the endpoints without changing onboarding history.

## Change Ownership

This change alone owns directory DTOs, filters, detail diagnostics and directory annotations. `add-revocable-client-auth-contract` owns token verification and logout, `add-api-problem-details` owns error serialization, and `add-no-store-response-policy` owns cache policy; this change neither duplicates nor changes them. `publish-openapi-export` owns the shared document builder and export command; it consumes route metadata. Shared source files must be merged additively, not replaced with snapshots from another branch. No requirement block is modified by two proposals.

## Open Questions

None blocking. The completion-only filter is an explicit initial scope decision.
