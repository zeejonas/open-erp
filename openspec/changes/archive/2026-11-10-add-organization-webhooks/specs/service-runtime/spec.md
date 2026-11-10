## ADDED Requirements

### Requirement: Independent webhook worker process
The application SHALL register `webhook-worker` as an AsyncCommand in the same executable/image used by the API. It SHALL run the dispatcher and sender loops, initialize database and webhook dependencies, apply production runtime-role safety checks and run until cancelled without opening an HTTP listener or fetching OIDC/JWKS keys. Compose SHALL expose a separate worker service using the existing safe runtime credentials and no published HTTP port. API serving SHALL not implicitly start a delivery loop. Operational documentation SHALL show independent API/worker startup and scaling, shared database connection budgeting, graceful shutdown and backlog recovery.

#### Scenario: Worker independent of identity provider
- **WHEN** a correctly configured worker starts without OIDC environment variables
- **THEN** it can process existing deliveries without starting authentication refresh or an HTTP listener

#### Scenario: API independent of worker availability
- **WHEN** workers are stopped but Postgres and normal API dependencies are available
- **THEN** supported API writes commit events and dispatch records and normal API health does not fail solely because workers are absent

### Requirement: Webhook runtime configuration
API serving and webhook-worker SHALL require `WEBHOOK_KEY_ENCRYPTION_KEY` containing base64-encoded 32-byte key material. Missing/malformed keys SHALL fail startup naming only the variable, never its value. The key SHALL be used only to encrypt per-subscription signing secrets at rest, never as a signing secret itself. Commands that apply subscription creation/rotation, including approval-override when applicable, SHALL require the same key before committing that operation; unrelated migrations, audit verification and offline OpenAPI export SHALL not require it. No key or secret SHALL be embedded in the image or repository. Test fixtures SHALL inject deterministic isolated test configuration.

The worker SHALL read these optional settings, each a positive integer:

| Variable | Default |
|---|---|
| `WEBHOOK_WORKER_CONCURRENCY` | 16 |
| `WEBHOOK_MAX_IN_FLIGHT_PER_ORGANIZATION` | 8 |
| `WEBHOOK_MAX_IN_FLIGHT_PER_SUBSCRIPTION` | 4 |
| `WEBHOOK_POLL_INTERVAL_MS` | 1000 |

Startup SHALL fail, naming the variable, when a value is malformed or when the per-subscription limit exceeds the per-organization limit. Worker concurrency SHALL apply per process; the per-organization and per-subscription limits SHALL be enforced from database lease state across processes as defined by webhook-delivery, and every worker process SHALL use the same values for them.

#### Scenario: Missing encryption key
- **WHEN** API serving or a worker starts without the webhook encryption key
- **THEN** startup fails without logging configured values or sending callbacks

#### Scenario: Inconsistent limits
- **WHEN** a worker starts with a per-subscription limit greater than its per-organization limit
- **THEN** startup fails naming both variables before any work is claimed

#### Scenario: Offline export remains independent
- **WHEN** export-openapi runs without database, webhook or OIDC credentials
- **THEN** the exported contract includes webhook routes/schemas without opening runtime connections
