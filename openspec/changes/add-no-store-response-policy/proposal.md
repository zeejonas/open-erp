## Why

Invitation tokens are returned by provisioning, reissue, ordinary invitation creation and approval-held invitation responses, but only two platform handlers set `Cache-Control: no-store`. A per-handler rule will be forgotten on the next token-bearing path.

## What Changes

- Install one global middleware that sets `Cache-Control: no-store` on every application response, including errors.
- Remove the manual platform handler assignments.

## Capabilities

### New Capabilities

- `api-response-contract`: Shared non-cacheable response policy.

### Modified Capabilities

None.

## Impact

One small middleware in `configure`, removal of two header assignments, and focused tests. SOX/SOC: credentials and tenant data are never stored by shared or browser caches.

## Non-goals

Per-route cache tuning, ETags, CDN configuration, and error formatting.
