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
