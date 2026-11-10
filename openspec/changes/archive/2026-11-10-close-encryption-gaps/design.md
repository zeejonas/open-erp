## Context

```
 client ──TLS?──▶ LB ──plain──▶ API :8080 ══TLS verified══▶ Postgres ── disk: deployment-defined
                                  │  └──http allowed──▶ IdP JWKS / userinfo
                       worker ══HTTPS verified══▶ webhook receivers
```

What's already in place: verified Postgres TLS that fails closed (the `service-runtime` spec), AES-GCM encryption of webhook signing secrets, redacted logs, and HTTPS-only webhook destinations. What's missing: HSTS, an encrypted LB → app hop, OIDC URL scheme enforcement, and any stated requirement for storage encryption.

## Goals / Non-Goals

**Goals:** close each transit gap with the smallest configuration surface, keep today's defaults wherever a change would break existing deployments without a security gain, and turn encryption at rest into a documented control an auditor can check.

**Non-Goals:** field-level encryption, KEK rotation, Postgres TLS in Compose, and in-app detection of storage encryption.

## Decisions

**HSTS comes from a small `AsyncMiddleware` registered `at: .beginning`, next to `NoStoreMiddleware`.** Registered there, it wraps `ProblemMiddleware`, so error responses get the header too (Vapor docs: Advanced → Middleware, order). Vapor has no built-in HSTS. The header is sent whatever the scheme of the incoming request. RFC 6797 §8.1 requires user agents to ignore it when it arrives over plain HTTP, and the app often can't see the original scheme behind a load balancer. Sending it unconditionally is therefore safe and needs no trust in `X-Forwarded-Proto`. `includeSubDomains` and `preload` are left out because the API can't speak for sibling hosts.
- Rejected: leaving HSTS to the load balancer. That can't be verified from the repository, and not every deployment's load balancer supports it.
- Rejected: sending the header only when `X-Forwarded-Proto: https`. That adds a trusted-header dependency for no benefit.

**In-process TLS uses Vapor's `app.http.server.configuration.tlsConfiguration = .makeServerConfiguration(certificateChain:privateKey:)`** with `NIOSSLCertificate.fromPEMFile` and `NIOSSLPrivateKey(file:format: .pem)` (Vapor docs: Advanced → Server → TLS). It's set only while configuring for `serve`, so other commands never read the files. With TLS set, Vapor serves HTTP/1 and HTTP/2 over TLS on the same port. Load balancers such as AWS ALB don't validate target certificates, so a self-signed certificate is enough to encrypt the hop.
- Rejected: a TLS sidecar (Envoy or stunnel). That's another moving part for something Vapor already supports.
- Rejected: requiring TLS by default. It would break every current deployment and local Compose for little gain inside a private network that is already isolated.

**OIDC URL validation lives in `configureAuthentication`, in the existing non-testing branch.** URLs are parsed with `URLComponents`, and the scheme must be `https`. `OIDC_ALLOW_INSECURE_HTTP` is parsed strictly as `true` or `false` and logs a warning, following the `DATABASE_TLS_MODE=disable` precedent. Certificate verification is already the default for the `app.client` that fetches JWKS and userinfo (AsyncHTTPClient defaults to full verification), so no client change is needed, and a test fixture confirms it.
- Rejected: always requiring https with no opt-out. That would block the load-test harness's local OIDC stub and on-premises IdPs behind a TLS-terminating proxy.

**Encryption at rest is a documented deployment control, not code.** Postgres has no SQL interface that reports storage encryption, and RDS exposes `StorageEncrypted` only through the AWS API. The README states the requirement, the AWS check (`aws rds describe-db-instances --query 'DBInstances[].StorageEncrypted'`), how encryption carries over to snapshots, read replicas and backups, and the snapshot-copy-with-KMS → restore → cutover route for an unencrypted instance (AWS RDS docs: Encrypting Amazon RDS resources).
- Rejected: an `aws` check in `audit-verify`. It would tie the app to one cloud and to IAM permissions.

## Risks / Trade-offs

- [The OIDC https check breaks a deployment using `http`] → It fails at startup, names the variable and gives the opt-out. It's called out as BREAKING in the proposal.
- [HSTS with a long max-age, followed by moving the API host to HTTP-only] → Browsers keep refusing HTTP for a year. The README says to lower the value before any such move. This is unlikely for an ERP API.
- [Certificates loaded at startup aren't reloaded] → Rotation means a rolling restart, which is documented. Hot reload is a non-goal.

## Migration Plan

1. Before upgrading, confirm the OIDC URLs are `https`, or set `OIDC_ALLOW_INSECURE_HTTP=true` and plan the switch.
2. Deploy. HSTS turns on automatically outside testing.
3. Optional: mount a certificate and key, set `HTTP_TLS_*`, and switch the load balancer target protocol to HTTPS.
4. Run the README's AWS check to confirm `StorageEncrypted=true`.

To roll back: `HSTS_MAX_AGE_SECONDS=0`, unset `HTTP_TLS_*`, or set the OIDC opt-out. No data or schema changes.

## Open Questions

None.
