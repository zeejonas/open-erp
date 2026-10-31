## Context

`PlatformController` sets `no-store` manually on provisioning and reissue. Ordinary and approval-held invitation creation also return tokens without it.

## Decisions

1. **One global AsyncMiddleware outside error handling.** It replaces `Cache-Control` with `no-store` on the returned response, so generated errors receive it too. Middleware runs in registration order, so register it before the error middleware. [Vapor middleware](https://docs.vapor.codes/advanced/middleware/).
2. **Apply to everything.** An ERP API has no responses worth caching today; covering public docs and unknown routes keeps the rule simple and impossible to miss.

Rejected alternatives:
- Per-handler assignments: missed on new token paths.
- Marker protocol on token DTOs or body inspection: more code, same gap for held approval responses.

## Risks / Trade-offs

- [Docs and openapi.json are not cached] → Negligible for an internal API; revisit per route if a real need appears.

## Change Ownership

Owns the no-store requirement. Wraps whatever error middleware is installed, including `add-api-problem-details`.
