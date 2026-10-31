## Context

Vapor's installed default `ErrorMiddleware` returns `{error, reason}`. Handlers throw ordinary `Abort` errors; `verifiedAccessToken()` maps failed verification to `Abort(.unauthorized)`. Tenant authorization deliberately returns the same 403 for unknown organizations and missing membership.

## Goals / Non-Goals

**Goals:** One stable error shape clients can branch on; no change to statuses, headers or authorization boundaries; safe details in every environment.

**Non-Goals:** Converting every handler to typed errors, domain codes without recovery semantics, cache policy, token revocation.

## Decisions

1. **Replace, don't stack, the error handler.** Rebuild `app.middleware` with the existing route logging middleware followed by one problem-details error middleware, so each failure is formatted and logged once. [Vapor errors](https://docs.vapor.codes/basics/errors/), [Vapor middleware](https://docs.vapor.codes/advanced/middleware/).
2. **Small explicit shape.** One `Problem` DTO with `type`, `title`, `status`, `detail`, `code` ([RFC 9457](https://www.rfc-editor.org/rfc/rfc9457.html)); `type` is `urn:open-erp:problem:<code>`; `title` is the HTTP reason phrase.
3. **Codes come from status unless explicit.** A typed `AbortError` carries an explicit code where a distinct recovery action exists; currently only `invalid_access_token`. All other errors map from status: `bad_request`, `unauthorized`, `forbidden`, `not_found`, `conflict`, `payload_too_large`, `unsupported_media_type`, `too_many_requests`, `internal_error` (any 5xx), `http_error` (other statuses). Never derive codes from `reason`.
4. **Safe details.** 4xx `detail` uses the existing `Abort` reason, so validation still names invalid parameters. 5xx `detail` is generic in every environment. Preserve `AbortError` headers; add a Bearer `WWW-Authenticate` challenge to any 401 that lacks one, with `error="invalid_token"` for `invalid_access_token` and no error code for a missing token ([RFC 6750 §3.1](https://www.rfc-editor.org/rfc/rfc6750#section-3.1)). Log like Vapor's `Logger.report(error:)`: 5xx at error level with the error, 4xx at warning with only status and code, since client error reasons may echo submitted values.
5. **Document once.** Add a reusable VaporToOpenAPI response helper for the problem media type/schema; routes reference it beside existing annotations.

Rejected alternatives:
- Keep `{error, reason}`: forces clients to parse text.
- A domain error enum for every handler: large migration with no client benefit.
- Codes derived from reason text: break when wording changes.

## Risks / Trade-offs

- [Breaking body format] → Pre-release; update annotations, docs and tests together with no dual format.
- [Detail leaks internals] → 5xx details are generic; 4xx details come only from deliberate `Abort` reasons.

## Migration Plan

No schema change. Deploy as one change; rollback restores the default middleware.

## Change Ownership

Owns the `api-response-contract` problem requirements and error middleware. `add-revocable-client-auth-contract` adds its revocation codes on top and lands after this change. `add-no-store-response-policy` installs its middleware around this one.
