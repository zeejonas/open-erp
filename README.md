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

Run the tests against a disposable database that has run `Database/bootstrap.sql`,
such as a fresh Compose `db`. `.env.testing` supplies the Compose role credentials:
```bash
swift test
```

For a fresh local Docker database, run `docker compose run --rm migrate` and
then `docker compose up -d app`. Compose uses the owner role for `migrate`
and `revert` and the runtime role for `app`. If you have an earlier disposable
Compose database, `docker compose down -v` removes its data and lets
PostgreSQL run the bootstrap on the next start.

Compose passes OIDC settings from `.env` or your shell to the API server. The
`migrate`, `prune-revoked-tokens`, `platform-admin`, `approval-override`, and
`audit-verify`
commands require database settings and can run without OIDC configuration or
provider access. After changing `.env`, run `docker compose up -d app` again
to recreate the container with the new settings.
See [Docker's environment configuration](https://docs.docker.com/compose/how-tos/environment-variables/set-environment-variables/).

## Database configuration

| Variable | Purpose |
| --- | --- |
| `DATABASE_HOST`, `DATABASE_USERNAME`, `DATABASE_PASSWORD`, `DATABASE_NAME` | Required outside testing. |
| `DATABASE_PORT` | PostgreSQL port, default `5432`. |
| `DATABASE_TLS_MODE` | Defaults to `require`, which verifies the certificate chain and hostname. Testing defaults to `disable`. |
| `DATABASE_CA_FILE` | Optional PEM bundle that replaces the system trust roots for PostgreSQL. The file must be readable and valid. |
| `DATABASE_MAX_CONNECTIONS_PER_EVENT_LOOP` | Maximum connections per Vapor event loop, default `4`. |

Add `DATABASE_TLS_MODE=disable` to an existing local `.env` when running the API
against the plaintext Compose database. Compose sets this for its own API and
migration containers. The app logs a warning when TLS is disabled outside testing.

For direct Amazon RDS connections, use the RDS endpoint as `DATABASE_HOST` and
set `DATABASE_CA_FILE=/app/certs/rds-global-bundle.pem` when running the API image.
For RDS Proxy, use its endpoint and the system trust store. RDS Proxy uses
public ACM certificates. [Amazon RDS TLS documentation](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/UsingWithRDS.SSL.html)

Budget up to `connections per event loop × event loops per instance × instance count`
against PostgreSQL's `max_connections`. Leave room for operational commands,
other clients, and overlapping instances during a rollout.

Point the load balancer's readiness check at `GET /health`. It returns
`{"status":"ok"}` after a successful database probe when signing keys are loaded,
or a generic 503 problem when either dependency is unavailable.

### Database roles and audit trail

On a fresh deployment, run `psql -X -f Database/bootstrap.sql` as a database
administrator connected to the target database. Migrations require this step
because it creates the `audit` schema. Provision separate credentials
for `open_erp_owner` and `open_erp_runtime` through your deployment's secret
management. Use the owner credentials for migrations and reserve them for
schema administration. Use the runtime credentials for the API. Production
serving rejects superuser and audit owner sessions.

After the first migration, run the following as the owner to remove the
runtime role's default access to Fluent's migration history. Repeat if the
migration history table is recreated.

```sql
REVOKE ALL ON TABLE public._fluent_migrations FROM open_erp_runtime;
```

Then run `swift run open-erp audit-verify` to check trigger coverage and unsafe
grants. It reports the runtime role's migration history access until that revoke runs. Tenant roles with `audit_event:read` can read recorded values
across all audited tables in their organization. Both organization role
templates include this permission. Platform administrators can use
`GET /platform/audit-events` to read global events.

The API takes audit IP addresses from the socket by default. Set
`TRUSTED_PROXY_COUNT` to the number of trusted forwarding hops if those
proxies append to `X-Forwarded-For`. The API counts from the right and falls
back to the socket address if the selected hop is missing or invalid.

The `platform-admin` command requires `--operator` for both grants and revocations:

```bash
swift run open-erp platform-admin admin@example.com Ada Lovelace 'auth0|123' --operator 'Database Operations'
```

If you deploy with RDS Proxy, measure
`DatabaseConnectionsCurrentlySessionPinned` under representative write load
before go-live. Audit attribution uses a transaction-local setting, and
PostgreSQL session settings can affect proxy connection reuse.
[Amazon RDS Proxy pinning documentation](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/rds-proxy-pinning.html)

## Encryption

### In transit

| Hop | Protection | Controlled by |
| --- | --- | --- |
| Client → load balancer | TLS terminated at the load balancer. Every API response carries `Strict-Transport-Security`, so browsers refuse to downgrade later requests. | Load balancer listener certificate; `HSTS_MAX_AGE_SECONDS` |
| Load balancer → API | Plain HTTP inside the private network by default. Set `HTTP_TLS_CERT_FILE` and `HTTP_TLS_KEY_FILE` to serve only TLS on the same port, then switch the load balancer's target protocol to HTTPS. | `HTTP_TLS_CERT_FILE`, `HTTP_TLS_KEY_FILE` |
| API and worker → PostgreSQL | TLS with certificate chain and hostname verification. There is no plaintext fallback. | `DATABASE_TLS_MODE`, `DATABASE_CA_FILE` |
| API → identity provider (JWKS, userinfo) | HTTPS with certificate chain and hostname verification. Outside testing, startup fails if either URL is not `https`. | `OIDC_JWKS_URL`, `OIDC_USERINFO_URL`, `OIDC_ALLOW_INSECURE_HTTP` |
| Worker → webhook receivers | HTTPS only, with certificate verification against the original hostname. | Destination URL validation |

| Variable | Purpose |
| --- | --- |
| `HSTS_MAX_AGE_SECONDS` | `max-age` for `Strict-Transport-Security`, default `31536000` (one year) outside testing. `0` turns the header off. The header omits `includeSubDomains` and `preload`, because the API can't speak for sibling hosts. |
| `HTTP_TLS_CERT_FILE`, `HTTP_TLS_KEY_FILE` | PEM certificate chain and private key for in-process HTTPS. Set both or neither. Only `serve` reads them. |
| `OIDC_ALLOW_INSECURE_HTTP` | `true` allows `http` identity provider URLs and logs a warning naming them. Use it only for a local stub or a provider behind a TLS-terminating proxy on the same host. Default `false`. |

Browsers ignore `Strict-Transport-Security` received over plain HTTP (RFC 6797 §8.1),
so the API sends it whatever the request scheme. Browsers remember it for the full
`max-age`. Lower `HSTS_MAX_AGE_SECONDS` and wait out the old value before ever
serving the API host over plain HTTP.

The load balancer → API hop can use a self-signed certificate, because load balancers
such as AWS ALB don't validate target certificates. The server loads certificates at
startup, so rotate them with a rolling restart.
[Vapor server TLS documentation](https://docs.vapor.codes/advanced/server/)

### At rest

| Storage | Protection |
| --- | --- |
| Database storage | Encrypted by the storage layer with a KMS key. Required in production; see below. |
| Snapshots, automated backups, read replicas | Inherit the source instance's encryption. |
| Webhook signing secrets | Also encrypted by the application with AES-GCM under `WEBHOOK_KEY_ENCRYPTION_KEY`. |
| Logs | The redacting log handler keeps tokens and credentials out. The log store's own encryption is a deployment control. |

Production database storage must be encrypted at rest with a KMS key. PostgreSQL can't
report storage encryption, so check it from the cloud API. On Amazon RDS:

```bash
aws rds describe-db-instances --db-instance-identifier YOUR_INSTANCE --query 'DBInstances[].[StorageEncrypted,KmsKeyId]'
```

RDS can't turn on encryption for an existing instance in place. To encrypt one, take a
snapshot, copy it with a KMS key, restore the encrypted copy to a new instance, and cut
over to its endpoint.
[Amazon RDS encryption documentation](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/Overview.Encryption.html)

Load `WEBHOOK_KEY_ENCRYPTION_KEY` from a secret manager, never from the image or the
repository. Anyone with both a database copy and this key can decrypt webhook signing secrets.

The local Compose database has neither TLS nor encryption at rest. Never put real data in it.

## API documentation

With the server running, open [Swagger UI](http://localhost:8080/docs).
The generated OpenAPI specification is available at `/openapi.json`.
Both documentation endpoints are public and contain API metadata only.
Swagger UI loads its pinned JavaScript and CSS from unpkg, so the browser needs internet access.

Use **Authorize** to enter an OIDC access token, then supply `X-Organization-ID`
on organization endpoints. Requests use the same authentication, membership, permission,
and approval checks as any other API client. “Try it out” executes real API requests.
Approval-controlled writes may return `202` with an approval request instead of applying immediately.

To export the same contract locally without starting a server, configuring OIDC,
or running Postgres:

```bash
swift run open-erp export-openapi /tmp/openapi.json
```

The destination's parent directory must exist. The command atomically writes
pretty-printed JSON with sorted keys; repeated exports of the same revision are
byte-identical. Missing arguments and write failures exit unsuccessfully.
Use the exported file with client generators or other API tooling.

Keep `.openAPI(...)` annotations beside route registrations when adding or changing endpoints.
Request and response schemas come from the existing DTOs. Both `/openapi.json` and
the export command use the same document builder and API version.
Approval responses use a synthetic example because their validating decoder cannot be reflected.
Add `.problemResponses(...)` beside route annotations for applicable failure statuses;
the helper includes authentication, authorization, and internal failures.
See [VaporToOpenAPI](https://github.com/dankinsoid/VaporToOpenAPI),
[Vapor routing](https://docs.vapor.codes/basics/routing/), and
[Swagger UI installation](https://swagger.io/docs/open-source-tools/swagger-ui/usage/installation/).

## Client authentication and logout

Any OIDC provider can supply JWT access tokens. Configure the exact `OIDC_ISSUER`
(including a trailing slash when present), `OIDC_AUDIENCE`, trusted `OIDC_JWKS_URL`,
and `OIDC_USERINFO_URL`. Both URLs must use `https` outside testing; see [Encryption](#encryption). The ERP verifies the signature with the configured JWKS,
requires matching `iss`, an `aud` containing the configured audience, and a future
`exp`. Send an **access token**, never an ID token, refresh token, or provider
session cookie. No provider-specific `jti`, roles, or permissions claim is required;
ERP memberships and permissions determine authorization.

The server fetches signing keys in the background and retries every 30 seconds
until the first success. After that it refreshes every five minutes and retains
the last good keys during provider outages. It ignores JWKS entries it cannot use
for signature verification, such as encryption keys, and logs how many it ignored.
Publish new keys before signing with them to allow time for the next refresh.
Requests with bearer tokens receive `authentication_unavailable` until the first
successful fetch.

The issuer controls expiration. Recommend 10-minute access tokens in the provider's
API configuration; the ERP does not enforce a maximum lifetime. Short expiry limits
exposure and complements revocation.

Clients own their login and session architecture. Browser and native mobile clients
can use Authorization Code with PKCE through their provider SDK. Keep browser tokens
in the SDK's memory storage and native credentials in the platform keychain/keystore.
Server-backed clients can keep tokens in a protected server session behind a secure,
HttpOnly cookie and forward the access token to the ERP. Protect cookie-authenticated
client actions against CSRF. The ERP does not issue tokens, maintain UI sessions,
accept those cookies, or require clients to access its database. Use HTTPS in deployment.

| Route class | Bearer access token | `X-Organization-ID` | Additional authorization |
| --- | --- | --- | --- |
| `GET /health` | No | No | Database and signing-key readiness |
| `GET /docs`, `GET /openapi.json` | No | No | Public API documentation |
| `/me`, `/me/organizations` | Yes | No | Bound, active ERP user |
| `GET /me/access` | Yes | Required | Active membership |
| `GET /permissions` | Yes | Required | Active membership and `role:read` |
| `POST /platform/organizations/:organizationID/restore` | Yes | No | Platform administrator and a restoration reason |
| `/platform/organizations` and its subroutes | Yes | No | Platform administrator |
| `POST /invitations/accept` | Yes | No | Valid invitation and verified matching email; user binding may be created here |
| `POST /auth/logout` | Yes | Forbidden | Standard JWT validation; user binding and membership unnecessary |
| `GET /approval-requests/awaiting-me` | Yes | Required | Active membership. Results include only pending requests the caller can approve. |
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
| 503 | `authentication_unavailable` | Retry later. Signing keys or the revocation store are unavailable. If this occurred during logout, revocation is unconfirmed. |
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


## Organization webhooks

Webhooks publish supported organization, company, role, group, relationship, invitation,
and approval transitions. Discover the explicit version 1 catalog at
`GET /webhook-event-types`; `/openapi.json` and `export-openapi` include the complete
allowlisted envelope and summary schemas. No wildcard subscribes to future event types.
Metadata history is available through `/webhook-events`, `/webhook-deliveries`, delivery
`/:id/attempts`, subscription `/:id/versions`, and subscription `/:id/health`.
All tenant routes require a bearer token, active membership, and `X-Organization-ID`.

Create a subscription with `POST /webhook-subscriptions`, supplying `name`, `url`,
`eventTypes`, and `companyIds` (an empty list means organization-wide). Creation is
disabled. PATCH with the current `expectedRevisionId` and `enabled: true` to activate.
A company filter is valid only for company and group-company events and active companies
in that organization. Other event types have a null `companyId`, including approvals.
The limit is 100 non-deleted subscriptions per organization. Configuration versions are
immutable; held changes fail if another version applies first.

Subscription create/update/delete can require approval. Update policies can independently
gate `name`, `url`, `eventTypes`, `companyIds`, `enabled`, and `rotateSecret`. The requester
must retain management and selected source-read grants at application; creation, expansion,
and enablement additionally require `webhook_payload:read`. Organization integrations
continue independently of the creator's later membership or login session. No webhook
approval policy is installed automatically.

`POST /webhook-subscriptions/:id/disable` requires `webhook_subscription:disable` and
immediately stops new authorizations, bypassing approval. Changing destinations or narrowing
scopes cancels unauthorized queued work rather than redirecting it. Requests already
authorized can finish, and their outcomes remain evidence. Name changes and rotation preserve
otherwise-authorized work. Organization deletion disables integrations and cancels queued
tenant work; restoration never re-enables subscriptions or revives cancelled deliveries.

The administrator template has every webhook permission. The viewer template has subscription,
event, and delivery metadata reads, and explicitly excludes `webhook_payload:read` and
`webhook_secret:read`. Management permissions do not imply either. Delivery payload inspection
also requires the event's source-read permission. Platform administrator status does not grant
these tenant capabilities. List routes reject undeclared/repeated parameters and have stable
paging; their exact filters and timestamp order are published in OpenAPI.

### Receiver verification and delivery semantics

Use a [Standard Webhooks receiver library](https://github.com/standard-webhooks/standard-webhooks)
and the raw request bytes. For example, the Python library verifies HMAC and timestamp freshness:

```python
from standardwebhooks.webhooks import Webhook

# raw_body is the received bytes, before JSON parsing or re-encoding.
event = Webhook(subscription_secret).verify(raw_body, request_headers)
```

The sender signs `webhook-id.webhook-timestamp.raw-body` using HMAC-SHA256, with
`webhook-signature: v1,<base64>`. `webhook-id` is the stable event UUID; the independent
`X-OpenERP-Attempt-ID` changes on each authorized attempt. Timestamps are fresh on retries.
Verify freshness with the library and keep clocks synchronized. Secret retrieval through
`POST /webhook-subscriptions/:id/secret` requires `webhook_secret:read`; each disclosure is
recorded before its `no-store` response. PATCH `rotateSecret: true` with the expected revision
to rotate, subject to update approval. Retrieve the newly applied secret through the same
recorded endpoint. Rotation is immediate and subsequent authorized attempts use only the new
secret; coordinate receivers accordingly. Dual signing is not supported in this release.

Deduplicate event IDs durably and atomically with business effects, or with insertion into a
durable internal processing queue. Acknowledge only after that transaction commits. Retain
receiver deduplication records for at least the 72-hour retry horizon plus operational recovery
margin. The sender can retry when a receiver accepted a request but its acknowledgment was
lost or a worker crashed. A 2xx response, including 202, means HTTP receipt; it does not prove
that downstream business processing finished. Neither global nor per-subscription ordering,
contiguous filtered revisions, nor exactly-once external effects are promised.

Events are captured even without subscriptions. Dispatch uses the highest configuration
version committed and visible at event capture, including explicit ordering inside the same
transaction, so later enablement and scope expansion do not receive historical events.
Filters can create revision gaps; organization restoration continues its resource revision
stream and does not restore deleted child resources. Payloads retain their original bytes
and never expand automatically with model DTOs. Bodies exclude invitation identities/tokens,
operator names, approval comments/proposed changes, secrets, and raw failure diagnostics.

Network failures, 408, 425, 429, and 5xx retry with full jitter starting at five seconds and
capped at six hours, within 72 hours of the first authorized attempt. Valid Retry-After on
429/503 is bounded by that deadline. Other responses, including redirects, are terminal.
Worker downtime before the first attempt does not consume the window. Expired in-flight
leases produce immutable `unknown` outcomes before safe retry, with the original event ID.
Continuous failure for 72 hours automatically pauses the subscription, records system
attribution and cancels its queued work. Acknowledgment clears `failingSince`; re-enabling a
paused integration follows ordinary approval and clears it as well. Health flags auto-pause,
queues older than five minutes, and exhaustion since the last acknowledgment. Re-enablement
only permits future events; cancelled/exhausted work is retained and has no replay route.

### API and worker deployment

Provide a base64-encoded 32-byte `WEBHOOK_KEY_ENCRYPTION_KEY` through deployment secret
injection to every API and worker process. For a disposable local deployment, generate one
outside the repository and preserve it across restarts. This key encrypts unique per-subscription
`whsec_` signing secrets with AES-GCM bound to organization, subscription and secret ID;
it is never a signing secret. API/worker startup fails for a missing or malformed key without
printing its value. Commands applying subscription creation/rotation need the key; unrelated
migrations, audit verification, pruning, and offline OpenAPI export remain independent.
Test fixtures inject isolated keys; the test-only receiver certificate/key under Tests is
not used by or copied into the runtime image.

The same executable/image runs independent processes:

```sh
docker compose run --rm migrate
docker compose up -d app webhook-worker
docker compose stop webhook-worker       # API writes still commit durable publication work
docker compose up -d --scale webhook-worker=2 webhook-worker
docker compose stop app                  # workers continue delivering committed work
```

API serving does not start worker loops. Workers do not listen on HTTP or initialize
OIDC/JWKS. Both require a safe runtime database role in production. Configure the shared
pool limits identically on every worker:

| Setting | Default | Meaning |
| --- | --- | --- |
| `WEBHOOK_WORKER_CONCURRENCY` | 16 | In-flight attempts per process |
| `WEBHOOK_MAX_IN_FLIGHT_PER_SUBSCRIPTION` | 4 | Exact shared endpoint ceiling |
| `WEBHOOK_MAX_IN_FLIGHT_PER_ORGANIZATION` | 8 | Approximate shared tenant fairness ceiling |
| `WEBHOOK_POLL_INTERVAL_MS` | 1000 | Idle dispatcher/sender polling interval |

All values must be positive integers, with subscription limit no larger than organization
limit. Each replica adds process capacity; organization counting can briefly overshoot under
concurrent claims. Claims lock one subscription and then one delivery, use SKIP LOCKED and
partial unfinished-work indexes, and hold no database transaction across HTTP. Requests have
a ten-second HTTP deadline and sixty-second lease. SIGTERM/SIGINT stop claims and cancel
in-flight tasks; Compose allows thirty seconds before termination. Unfinished starts survive
restart and recover as unknown. Size database connection budgets for separate API and worker
pools: each process can use event-loop count times `DATABASE_MAX_CONNECTIONS_PER_EVENT_LOOP`
connections. Increasing replicas also increases this upper bound.

Every sixty seconds a worker logs its in-flight count, dispatch lag, oldest due queue age,
and median/maximum claim duration. Health includes median attempt duration over 24 hours.
Logs omit payloads, response bodies and secrets. Use these measurements before changing
limits or adopting deferred connection reuse, batch claims, or partitioning.

Restrict worker egress to the destinations your deployment permits. URLs require HTTPS on
443 with a hostname and no credentials, query or fragment. Every attempt vets all resolved
IPv4/IPv6 addresses, rejects non-public/metadata destinations, pins connection establishment
to a vetted numeric address, retains original-host TLS/SNI verification and refuses redirects.
Network controls remain valuable alongside the application check. The initial transport uses
a separate bounded client per attempt, sharing event loops and closing it afterward.

### Webhook migration and recovery

This repository is pre-release: each table has one owning create migration, and existing
create definitions are edited in place. Reset disposable pre-release databases and run fresh
migrations; do not upgrade retained databases through ad hoc ALTER scripts or silently promote
custom roles. Fresh template copies include the new permissions; existing copied roles are
ordinary data and are never automatically broadened.

Back up the encryption key securely with the database recovery procedure, separately from
ordinary source/configuration backups, and test restoring both together. Losing or replacing
it makes stored signing secrets unavailable. Events, configuration revisions, secret reveals,
and delivery entries are immutable and retained indefinitely; audit snapshots omit duplicated
payload bytes and ciphertext. Queue scheduling is mutable; delivery INSERT/DELETE are audited
and its attempt/cancellation ledger carries scheduling evidence. The transient dispatch queue
has no row-capture trigger. `audit-verify` enforces these exact capture scopes.

For rollback, stop workers first and preserve evidence, the key, dispatch records and delivery
state. Correct schema/code forward and restart with the same key/runtime credentials. Avoid
manual evidence rewrites or evidence deletion. Receiver idempotency handles unknown remote
outcomes. Replay, synthetic deliveries, cross-table reconciliation, archive infrastructure and
production retention policy are separate changes.

## Load testing

`LoadTests/` measures how many requests per second each user, company and webhook endpoint
supports. It runs on demand only, never in `swift test` or CI. The only prerequisite is Docker.

```bash
LoadTests/run.sh
```

The script builds the production image and starts a separate Compose project
(`open-erp-loadtest`) with its own database volume, an OIDC stub and the webhook worker, all on
an internal network with no route off the host. It refuses to run unless the database is
`open_erp_loadtest`. It creates a platform administrator with the CLI, seeds organizations,
members, companies, subscriptions and events through the API, runs the worker until every
delivery has an attempt (each fails at name resolution, because the destinations use `.invalid`),
then stops the worker and measures. At the end it removes the stack and its database; `--keep`
leaves them running for inspection. Dataset sizes, steps and latency budgets are in
`LoadTests/config.json`; pass another file with `--config`. The default plan takes about two and
a half hours. For a quick check, `LoadTests/run.sh --config LoadTests/config.smoke.json` runs every
endpoint for 10 s at 200 RPS on a smaller dataset, in about 15 minutes. It reports pass or fail at
that rate rather than a supported RPS, so compare smoke runs only with other smoke runs.

Each endpoint is driven at an open arrival rate in steps (25 to 1600 RPS, 30 s each). Reads run
before writes, and lists use the default page size, with one `per=100` event-list variant.
Subscription create, patch, delete and disable run at lower rates (2 to 40 RPS): creates
serialize per organization to enforce the 100-subscription limit, and they are rare in real
traffic. When a scenario needs setup or cleanup requests (a company to delete, a subscription to
patch), those count toward the step's rate, so the rate is always what the API receives; the
report's Requests column shows how many requests each iteration sends. A step
passes when p95 latency is within budget (300 ms reads, 500 ms writes), under 1% of requests
fail, and at least 95% of the target requests were sent. **Supported RPS** is the highest
passing step before the first failing one; "≥" means no step failed, so the figure is a lower
bound. A step where k6 fell behind while the API stayed within budget is marked
*generator-bound*: give k6 more CPUs (`K6_CPUS`) rather than reading it as an API limit.
A weighted mixed workload runs last. Throughout the run, a 5 RPS stream of cross-tenant,
missing-permission and invalid-token requests must always be refused; any success fails the run.

Reports go to `LoadTests/reports/<timestamp>/report.md` and `report.json` (git-ignored). They
record per-step p50/p95/p99 and error rate, peak `open_erp_runtime` connections against the
pool ceiling (event loops × `DATABASE_MAX_CONNECTIONS_PER_EVENT_LOOP`), the git commit, the app's
CPU and memory limits (`APP_CPUS`, `APP_MEMORY`, defaults 2 and `1g`), the host CPU count and
the dataset. They contain no tokens, secrets or response bodies. Compare runs only on like hosts
with the same limits. On macOS, Docker's virtual machine adds overhead and shares CPUs with k6,
so treat absolute figures as relative.

The harness does not cover other route groups, outbound webhook delivery throughput,
approval-held writes, database TLS, or multi-replica deployments.
