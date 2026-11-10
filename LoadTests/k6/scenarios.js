// Measures every route in lib/routes.js with step load, then a mixed workload, while a
// low-rate isolation stream runs throughout. handleSummary writes /out/results.json, which
// report.js turns into the run report. Nothing here writes tokens or response bodies.
import exec from 'k6/execution';
import { Counter } from 'k6/metrics';
import { mint, must, send, waitForHealth } from './lib/api.js';
import { buildPlan } from './lib/steps.js';
import { context, routes, routesByKey, uncoveredRoutes } from './lib/routes.js';

const config = JSON.parse(open('/config/config.json'));
const seed = JSON.parse(open('/out/seed.json'));
const plan = buildPlan(routes, config);

const isolationChecks = new Counter('isolation_checks');
const isolationFailures = new Counter('isolation_failures');

export const options = {
  scenarios: plan.scenarios,
  thresholds: plan.thresholds,
  setupTimeout: '5m',
  summaryTrendStats: ['med', 'p(95)', 'p(99)'],
  // Without `url`, per-ID URLs don't create a time series each.
  systemTags: ['scenario', 'name', 'method', 'status', 'error_code'],
};

function ids(path, token, org) {
  const items = must(200, 'GET', `${path}?per=100`, { token, org, name: path }).json('items');
  if (items.length === 0) throw new Error(`${path} returned no items; seeding is incomplete`);
  return items.map((item) => item.id);
}

export function setup() {
  waitForHealth();

  const missing = uncoveredRoutes(must(200, 'GET', '/openapi.json').json());
  if (missing.length > 0) {
    throw new Error(`Routes without a load scenario: ${missing.join(', ')}`);
  }

  const organizations = seed.organizations.map((org) => {
    const adminTokens = org.admins.map((a) => mint(a.sub, a.email));
    return {
      id: org.id,
      adminTokens,
      memberTokens: org.members.map((m) => mint(m.sub, m.email)),
      userIds: [...org.admins, ...org.members].map((u) => u.userId),
      companies: org.companies,
      subscriptions: org.subscriptions,
      deliveries: ids('/webhook-deliveries', adminTokens[0], org.id),
      events: ids('/webhook-events', adminTokens[0], org.id),
    };
  });

  const [a] = seed.organizations;
  return {
    organizations,
    expiredToken: mint(a.members[0].sub, a.members[0].email, { expiresIn: -120 }),
    unpublishedToken: mint(a.members[0].sub, a.members[0].email, { unpublishedKey: true }),
    startedAt: Date.now(),
  };
}

export function run(data) {
  routesByKey[exec.scenario.name.split('__')[0]].run(context(data));
}

const weights = Object.entries(config.mixed.weights);
const weightTotal = weights.reduce((sum, [, w]) => sum + w, 0);

export function mixed(data) {
  let roll = Math.random() * weightTotal;
  for (const [key, weight] of weights) {
    roll -= weight;
    if (roll < 0) return routesByKey[key].run(context(data));
  }
}

/** Requests that must always be refused, whatever the load. */
const isolationCases = [
  ['wrong organization header', 403, (d, a, b) => send('GET', '/companies?per=1', { token: a.memberTokens[0], org: b.id, name: 'isolation' })],
  ['cross-tenant company', 404, (d, a, b) => send('GET', `/companies/${b.companies[0]}`, { token: a.adminTokens[0], org: a.id, name: 'isolation' })],
  ['cross-tenant delivery', 404, (d, a, b) => send('GET', `/webhook-deliveries/${b.deliveries[0]}`, { token: a.adminTokens[0], org: a.id, name: 'isolation' })],
  ['missing webhook_secret:read', 403, (d, a) => send('POST', `/webhook-subscriptions/${a.subscriptions[0]}/secret`, { token: a.memberTokens[0], org: a.id, name: 'isolation' })],
  ['missing token', 401, () => send('GET', '/me', { name: 'isolation' })],
  ['expired token', 401, (d) => send('GET', '/me', { token: d.expiredToken, name: 'isolation' })],
  ['unpublished signing key', 401, (d) => send('GET', '/me', { token: d.unpublishedToken, name: 'isolation' })],
];

export function isolation(data) {
  const [label, expected, request] = isolationCases[exec.scenario.iterationInTest % isolationCases.length];
  const [a, b] = data.organizations;
  const res = request(data, a, b);
  isolationChecks.add(1);
  if (res.status !== expected) {
    isolationFailures.add(1);
    console.error(`Isolation check failed: ${label} returned ${res.status}, expected ${expected}`);
  }
}

function stepResult(data, step) {
  const latency = data.metrics[`http_req_duration{scenario:${step.name},measured:true}`];
  const errors = data.metrics[`errors{scenario:${step.name}}`];
  const sent = data.metrics[`iterations{scenario:${step.name}}`];
  const ok = (metric) => !!metric && Object.values(metric.thresholds || {}).every((t) => t.ok);
  return {
    ...step,
    p50: latency ? latency.values.med : null,
    p95: latency ? latency.values['p(95)'] : null,
    p99: latency ? latency.values['p(99)'] : null,
    errorRate: errors ? errors.values.rate : 1,
    sent: sent ? sent.values.count : 0,
    latencyOk: ok(latency),
    errorsOk: ok(errors),
    sentOk: ok(sent),
  };
}

export function handleSummary(data) {
  const results = {
    startedAt: data.setup_data ? data.setup_data.startedAt : null,
    totalSeconds: plan.totalSeconds,
    config,
    dataset: seed.dataset,
    routes: routes.map(({ key, method, path, write, requests, lowFrequency }) => ({ key, method, path, write: !!write, requests: requests || 1, lowFrequency: !!lowFrequency })),
    steps: plan.timeline.map((step) => stepResult(data, step)),
    isolation: {
      checks: data.metrics.isolation_checks ? data.metrics.isolation_checks.values.count : 0,
      failures: data.metrics.isolation_failures ? data.metrics.isolation_failures.values.count : 0,
    },
  };
  return { '/out/results.json': JSON.stringify(results, null, 2) };
}
