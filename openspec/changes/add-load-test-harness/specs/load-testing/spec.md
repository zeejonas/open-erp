## ADDED Requirements

### Requirement: Isolated on-demand harness
The repository SHALL provide a load-test harness under `LoadTests/` that an operator starts with one command. The harness SHALL run the production application image in production mode in its own Compose project, with its own database volume, CPU and memory limits, and the safe runtime database role. It SHALL refuse to start if the target database name is not the harness's own. It SHALL NOT run as part of `swift test` or CI. Running it SHALL require only Docker on the host.

#### Scenario: One-command run
- **WHEN** an operator runs the harness script on a machine with Docker
- **THEN** the harness builds the image, starts its own stack, seeds data, runs the scenarios, writes a report and stops its stack

#### Scenario: Wrong database refused
- **WHEN** the harness is pointed at a database other than its own
- **THEN** it exits before seeding and makes no requests

### Requirement: Realistic seeding through supported paths
The harness SHALL seed through the platform-admin command and the HTTP API, never by writing to tables directly. A local OIDC stub SHALL publish the JWKS the API verifies, mint access tokens for seeded subjects and answer userinfo for invitation acceptance. The seed SHALL contain at least two organizations, each with members, companies, webhook subscriptions, business events and delivery history. Delivery history SHALL come from running the webhook worker against unresolvable destinations (the `.invalid` top-level domain), so no traffic leaves the host. The worker SHALL be stopped before measurement starts. Approval policies SHALL NOT be seeded, so writes apply immediately. Dataset sizes SHALL be configurable and SHALL appear in the report.

#### Scenario: Seeded data is audited
- **WHEN** seeding completes
- **THEN** every seeded company and subscription has audit events that name the seeding user as the actor

#### Scenario: No external delivery
- **WHEN** the worker processes seeded deliveries
- **THEN** each attempt fails at name resolution and is recorded, with no connection to an external host

### Requirement: Per-endpoint coverage
The harness SHALL include one scenario per route for these endpoints:
- Users: `GET /users`, `GET /users/:userID`, `GET /me`, `PATCH /me`, `GET /me/access`, `GET /me/organizations`
- Companies: `GET /companies`, `POST /companies`, `GET /companies/:companyID`, `PATCH /companies/:companyID`, `DELETE /companies/:companyID`
- Webhooks: `POST /webhook-subscriptions`, `GET /webhook-subscriptions`, `GET /webhook-subscriptions/:subscriptionID`, `GET /webhook-subscriptions/:subscriptionID/versions`, `PATCH /webhook-subscriptions/:subscriptionID`, `DELETE /webhook-subscriptions/:subscriptionID`, `POST /webhook-subscriptions/:subscriptionID/disable`, `POST /webhook-subscriptions/:subscriptionID/secret`, `GET /webhook-subscriptions/:subscriptionID/health`, `GET /webhook-deliveries`, `GET /webhook-deliveries/:deliveryID`, `GET /webhook-deliveries/:deliveryID/attempts`, `GET /webhook-deliveries/:deliveryID/payload`, `GET /webhook-event-types`, `GET /webhook-events`, `GET /webhook-events/:eventID`, `GET /webhook-events/:eventID/payload`

List scenarios SHALL request the endpoint's default order and a page size of 100, and SHALL also run one declared filter. Scenarios that consume a resource (delete, disable) SHALL create the resource in the same iteration and report only the consuming request's latency. Every scenario SHALL check that the expected success status is returned. A route in these groups with no scenario SHALL make the run fail.

#### Scenario: Endpoint without a scenario
- **WHEN** a new route is added to the user, company or webhook controllers and the harness has no scenario for it
- **THEN** the harness compares its scenarios against the exported OpenAPI document and fails before load starts, naming the route

#### Scenario: Unexpected status
- **WHEN** a company write returns 202 instead of the expected direct result
- **THEN** that request counts as an error for the scenario

### Requirement: Supported RPS definition
Each scenario SHALL apply a constant arrival rate in increasing steps, running each step for a fixed time. A step SHALL pass when p95 latency is within the scenario's budget, fewer than 1% of requests fail, and at least 95% of the target arrivals were sent. The supported RPS for an endpoint SHALL be the highest passing step that comes before the first failing step. Step rates, step length and latency budgets SHALL be configurable, with defaults of 300 ms p95 for reads and 500 ms p95 for writes. Scenarios SHALL run one at a time, with a pause between them. A mixed scenario SHALL then run a weighted blend of the routes at a configurable rate.

#### Scenario: Saturation found
- **WHEN** steps at 200, 400 and 800 RPS pass and the step at 1600 RPS exceeds the p95 budget
- **THEN** the report gives 800 RPS as the endpoint's supported RPS, with the 1600 RPS step marked as the failing one

#### Scenario: Never saturated
- **WHEN** every step passes
- **THEN** the report gives the top step as a lower bound, marked "≥"

### Requirement: Tenant isolation and authorization under load
While the scenarios run, the harness SHALL send a steady stream of negative requests and SHALL fail the run if any one succeeds or returns another tenant's data:
- a valid token with another organization's ID in `X-Organization-ID`
- a resource ID belonging to another organization
- a member without the endpoint's permission
- a missing, expired or wrongly signed token

#### Scenario: Cross-tenant resource under load
- **WHEN** a member of organization A requests organization B's company or delivery while the endpoint is saturated
- **THEN** every response is 404 and the run records zero isolation failures

#### Scenario: Missing permission under load
- **WHEN** a member whose role lacks `webhook_secret:read` requests a secret disclosure
- **THEN** every response is 403 and no disclosure record is written

#### Scenario: Invalid token
- **WHEN** a request carries a token signed by a key that is not in the JWKS
- **THEN** every response is 401

### Requirement: Run report
Each run SHALL write a Markdown report and a JSON report to a timestamped folder under `LoadTests/reports/`. The report SHALL include, per endpoint: supported RPS, p50/p95/p99 latency and error rate at each step, and the first failing step. The run SHALL report the peak number of database connections held by the runtime role, the isolation-check totals, the dataset sizes, the git commit, the application's CPU and memory limits, the host's CPU count, and the database pool setting. The report SHALL NOT contain tokens, signing secrets or response bodies.

#### Scenario: Report produced
- **WHEN** a run completes
- **THEN** the report folder holds both files, and the Markdown file has one row per endpoint giving its supported RPS

#### Scenario: Secrets excluded
- **WHEN** the secret-disclosure scenario runs
- **THEN** neither report contains a `whsec_` value or a bearer token
