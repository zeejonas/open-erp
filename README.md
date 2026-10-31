# open-erp
Enterprise software without the robbery.

## Getting Started

Create a local `.env` from `.env.example` and configure Postgres and OIDC before
starting the server. Vapor reads `.env` from the working directory; run commands
from the project root. In Xcode, set the scheme's working directory to that same
folder. Existing process environment variables override `.env` values.

For Auth0, register an API under **Applications → APIs** with identifier
`https://api.open-erp.local` and RS256 signing. This identifier is the backend's
`OIDC_AUDIENCE`. Your SPA under **Applications → Applications** is the login
client; its Client ID is separate from the API audience. No client secret is
required by this backend.

Find your tenant's endpoints at
`https://YOUR_AUTH0_DOMAIN/.well-known/openid-configuration` and map them into `.env`:

| Variable | Auth0 value |
| --- | --- |
| `OIDC_ISSUER` | `issuer`, including its trailing slash |
| `OIDC_AUDIENCE` | The registered API's Identifier |
| `OIDC_JWKS_URL` | `jwks_uri` |
| `OIDC_USERINFO_URL` | `userinfo_endpoint` |

When logging in through the SPA, request that API audience and the
`openid profile email` scopes, then send the access token as a Bearer token.
Configure the SPA's callback, logout, and web origin URLs for the frontend that
performs login.

See [Auth0 API settings](https://auth0.com/docs/get-started/apis/api-settings) and
[Vapor environment configuration](https://docs.vapor.codes/basics/environment/).

To build the project using the Swift Package Manager, run the following command in the terminal from the root of the project:
```bash
swift build
```

To run the project and start the server, use the following command:
```bash
swift run
```

To execute tests, use the following command:
```bash
swift test
```

For Docker, run `docker compose up -d app` after building the image. Compose
reads the OIDC values from `.env` or your shell and passes them to the app,
migrate, and revert containers at runtime. `.env` files are excluded from the
image build context. After changing `.env`, run `docker compose up -d app` again
to recreate the container with the new values; no image rebuild or terminal
reload is needed. `docker compose restart` does not reload environment values.
See [Docker's environment configuration](https://docs.docker.com/compose/how-tos/environment-variables/set-environment-variables/).

## API documentation

With the server running, open [Swagger UI](http://localhost:8080/docs).
The generated OpenAPI specification is available at `/openapi.json`.
Both documentation endpoints are public and contain API metadata only.
Swagger UI loads its pinned JavaScript and CSS from unpkg, so the browser needs internet access.

Use **Authorize** to enter an OIDC access token, then supply `X-Organization-ID`
on organization endpoints. Requests use the same authentication, membership, permission,
and approval checks as any other API client. “Try it out” executes real API requests.
Approval-controlled writes may return `202` with an approval request instead of applying immediately.

Keep `.openAPI(...)` annotations beside route registrations when adding or changing endpoints.
Request and response schemas come from the existing DTOs; no generated spec needs to be checked in.
Approval responses use a synthetic example because their validating decoder cannot be reflected.
Add `.problemResponses(...)` beside route annotations for applicable failure statuses;
the helper includes authentication, authorization, and internal failures.
See [VaporToOpenAPI](https://github.com/dankinsoid/VaporToOpenAPI),
[Vapor routing](https://docs.vapor.codes/basics/routing/), and
[Swagger UI installation](https://swagger.io/docs/open-source-tools/swagger-ui/usage/installation/).

## Client authentication and logout

Any OIDC provider can supply JWT access tokens. Configure the exact `OIDC_ISSUER`
(including a trailing slash when present), `OIDC_AUDIENCE`, trusted `OIDC_JWKS_URL`,
and `OIDC_USERINFO_URL`. The ERP verifies the signature with the configured JWKS,
requires matching `iss`, an `aud` containing the configured audience, and a future
`exp`. Send an **access token**, never an ID token, refresh token, or provider
session cookie. No provider-specific `jti`, roles, or permissions claim is required;
ERP memberships and permissions determine authorization.

The issuer controls expiration. Recommend 10-minute access tokens in the provider's
API configuration; the ERP does not enforce a maximum lifetime. Short expiry limits
exposure but does not replace revocation. JWKS is loaded at application startup;
coordinate key changes with serving instances.

Clients own their login and session architecture. Browser and native mobile clients
can use Authorization Code with PKCE through their provider SDK. Keep browser tokens
in the SDK's memory storage and native credentials in the platform keychain/keystore.
Server-backed clients can keep tokens in a protected server session behind a secure,
HttpOnly cookie and forward the access token to the ERP. Protect cookie-authenticated
client actions against CSRF. The ERP does not issue tokens, maintain UI sessions,
accept those cookies, or require clients to access its database. Use HTTPS in deployment.

| Route class | Bearer access token | `X-Organization-ID` | Additional authorization |
| --- | --- | --- | --- |
| `/`, `/hello`, `/docs`, `/openapi.json` | No | No | Public metadata/health examples |
| `/me`, `/me/organizations` | Yes | No | Bound, active ERP user |
| `/platform/organizations` and its subroutes | Yes | No | Platform administrator |
| `POST /invitations/accept` | Yes | No | Valid invitation and verified matching email; user binding may be created here |
| `POST /auth/logout` | Yes | Forbidden | Standard JWT validation; user binding and membership unnecessary |
| Organization, company, user, membership, role, group and approval routes | Yes | Required | Active membership and the route's stated ERP permission |

For invitation acceptance, request `openid profile email` and the ERP API audience
when acquiring the token. The provider must support using that access token at the
configured userinfo endpoint and return `email` and `email_verified: true` (boolean
or string). The email must match the invitation. No user is created merely by
presenting a token. Unbound subjects receive 403 outside invitation acceptance and
logout. Removed users can still log out. Missing credentials return 401; missing
membership, insufficient permission, or an unbound identity returns 403. Selecting
an organization header does not grant membership. Check `/me/organizations` for
active memberships; keep organization selection in the client.

Synthetic HTTP examples (replace placeholders locally; never put tokens in URLs):

```http
GET /companies HTTP/1.1
Authorization: Bearer SYNTHETIC_ACCESS_TOKEN
X-Organization-ID: 00000000-0000-0000-0000-000000000001
```

```http
POST /auth/logout HTTP/1.1
Authorization: Bearer SYNTHETIC_ACCESS_TOKEN
Content-Length: 0
```

Logout takes no body, query parameters, or tenant selector. A successful empty
**204** confirms that this exact token's revocation is committed to shared Postgres.
Repeated or concurrent logout with that still-valid token also returns 204 and
preserves its first revocation timestamp. Invalid/expired tokens return 401;
unsupported inputs return 400. Storage read/write failures return 503
`authentication_unavailable`, with no claim of successful revocation.

Client logout ordering:

1. Stop refresh timers, silent renewal, and other token acquisition; coordinate
   pending refresh operations and other tabs/workers so they cannot retain or mint
   a replacement unnoticed. If an operation already minted a distinct token, each
   token needs its own ERP logout.
2. Submit the current access token to `POST /auth/logout` and wait for 204 before
   claiming ERP revocation. On a network failure, timeout, or 503, retry while the
   token is available. A lost response is safe to retry. An expired token's 401
   means it is no longer accepted by the ERP, not that a revocation was recorded.
3. Clear local credentials and client session state. If local clearing happens
   despite a failed/unconfirmed request, describe it as local logout only; clearing
   credentials alone does not prove server-side revocation.
4. Perform the provider's separate refresh-credential revocation and SSO/session
   logout as appropriate. These are client/provider operations. Never send a
   provider secret or refresh token to ERP logout.

ERP logout applies to the exact supplied access token at this ERP, across every
organization and serving instance. Other issued tokens/devices for the same subject
remain valid under ordinary authorization. It does not end provider SSO or revoke
refresh credentials. See your provider's documentation, for example
[Auth0 refresh-token revocation](https://auth0.com/docs/secure/tokens/refresh-tokens/revoke-refresh-tokens).

Every protected verification reads the primary database with no local negative
cache. Once logout commits, subsequent verification rejects the token with 401
`access_token_revoked`, including invitation acceptance. A request admitted before
that commit may finish; logout does not cancel requests already authorized.
A revocation-store outage fails closed with 503 and admits no protected operation.

### Operations and rollout

`revoked_access_tokens` holds only SHA-256 fingerprints of each token's signed header
and payload, so a re-encoded signature cannot dodge revocation, plus verified
issuer/subject, expiry, and first server revocation time; it has no ERP user or organization foreign
key. Treat it as shared security state. All instances must use the same **primary**
Postgres database, with no read replica or per-instance cache for authentication.

Before cutover, use the new build's native migration command (`swift run open-erp
migrate --yes`, or `docker compose run --rm migrate`) to create the table. Verify the
migration succeeded and run the revocation tests against the deployment's test
Postgres. Drain/stop protected traffic to old instances, replace **all** serving
instances with revocation-aware builds, and smoke-test logout on one instance and
replay on another before resuming traffic and advertising the guarantee. Mixed
old/new serving instances cannot enforce logout consistently. This is deployment
operator work; applying this source change does not perform a production cutover.

Roll back only to a revocation-aware build, retaining the table and records. Never
route protected requests to revocation-unaware code after issuing successful
logouts. If such a rollback is unavoidable, stop protected traffic until all
potentially affected tokens have expired using their actual issuer lifetimes;
the recommended ten minutes is not an enforced maximum. Do not revert/drop this
table during an active deployment. Pre-release development schema changes follow
the owning-create policy; fresh/revert tests run against a disposable database.

Schedule the native cleanup command through your operations scheduler:

```bash
swift run open-erp prune-revoked-tokens
```

It removes only records with expiry at or before the command's server time and
reports an exact deletion count. Keep hosts time-synchronized. Unexpired records
must survive cleanup, restarts and deployments. First committed revocations log
verified issuer, subject and server time without the access token or fingerprint;
retries do not create another audit event. Keep these security logs under deployment
access controls and SOX/SOC retention policy after expired enforcement rows are pruned.
Database/query logs must use the application's redacting log handler; avoid logging
Authorization, raw tokens, fingerprints, or credential-bearing URLs in proxies and
observability tools. Database insertion and logging are separate: a process crash
after commit can lose the emitted log event; the durable row remains the enforcement
and attribution source until expiry cleanup.

The implementation follows [Vapor JWT](https://docs.vapor.codes/security/jwt/),
[Fluent models](https://docs.vapor.codes/fluent/model/),
[Fluent schema](https://docs.vapor.codes/fluent/schema/),
[Vapor commands](https://docs.vapor.codes/advanced/commands/), and
[SQLKit's bound queries](https://github.com/vapor/sql-kit).

## API errors

Application errors use [RFC 9457 problem details](https://www.rfc-editor.org/rfc/rfc9457.html)
with `Content-Type: application/problem+json`:

```json
{
  "type": "urn:open-erp:problem:invalid_access_token",
  "title": "Unauthorized",
  "status": 401,
  "detail": "Unauthorized",
  "code": "invalid_access_token"
}
```

Branch on `code` and HTTP status, not text in `title` or `detail`. The body status
matches the HTTP status; `type` is always `urn:open-erp:problem:<code>`.

| HTTP status | Code | Client action |
| --- | --- | --- |
| 400 | `bad_request` | Correct the named input or tenant header. |
| 401 | `unauthorized` | Supply a bearer access token. |
| 401 | `invalid_access_token` | Obtain a valid access token; verification rejected the supplied token. |
| 401 | `access_token_revoked` | Stop using this token; require an intentional new login when appropriate. |
| 503 | `authentication_unavailable` | Retry later; authentication storage is unavailable and logout is unconfirmed. |
| 403 | `forbidden` | Check membership and permissions; repeating the request cannot grant access. |
| 404 | `not_found` | Check the route or resource within the selected organization. |
| 409 | `conflict` | Reload the resource and resolve the conflicting state. |
| 413 | `payload_too_large` | Reduce the request body size. |
| 415 | `unsupported_media_type` | Use the endpoint's documented request media type. |
| 429 | `too_many_requests` | Back off; respect `Retry-After` when present. |
| Any 5xx | `internal_error` | Retry as appropriate for the operation; contact the operator if it persists. |
| Other error statuses | `http_error` | Handle according to the HTTP status. |

Every 401 includes an [RFC 6750](https://www.rfc-editor.org/rfc/rfc6750#section-3.1) Bearer
`WWW-Authenticate` challenge: `Bearer error="invalid_token"` for a rejected token, plain
`Bearer` when no token was sent. Applicable error headers
are preserved. Internal error details are generic in all environments. Unknown
organizations and organizations without membership return the same generic 403.
New explicit codes require documented recovery semantics and tests.

### See more

- [Vapor Website](https://vapor.codes)
- [Vapor Documentation](https://docs.vapor.codes)
- [Vapor GitHub](https://github.com/vapor)
- [Vapor Community maintained packages](https://github.com/vapor-community)
