// One entry per measured route. `method` and `path` match /openapi.json, which the coverage
// check compares against this list. Filter variants reuse their route's method and path.
import exec from 'k6/execution';
import { Rate } from 'k6/metrics';
import { send } from './api.js';

export const errors = new Rate('errors');
const COMPANY_EVENTS = ['company.created', 'company.updated', 'company.deleted'];

function pick(items) {
  return items[Math.floor(Math.random() * items.length)];
}

/** The request whose latency counts. Any other status than `status` is an error. */
function measured(status, method, path, options) {
  const res = send(method, path, { ...options, tags: { measured: 'true' } });
  errors.add(res.status !== status);
  return res;
}

/** Setup or cleanup inside an iteration. A failure counts as an error for the step. */
function prep(status, method, path, options) {
  const res = send(method, path, { ...options, tags: { measured: 'false' } });
  if (res.status !== status) {
    errors.add(true);
    return null;
  }
  return res;
}

/** Unique 2–10 character alphanumeric company code for this VU and iteration. */
function uniqueCode() {
  return `L${exec.vu.idInTest.toString(36)}I${exec.vu.iterationInInstance.toString(36)}`.toUpperCase().slice(0, 10);
}

/** Picks an organization by VU so tenants share the load, then random actors and resources. */
export function context(data) {
  const orgs = data.organizations.length;
  const org = data.organizations[exec.vu.idInTest % orgs];
  return {
    org,
    // This VU's own index within its organization, so concurrent writes don't race on one row.
    slot: Math.floor(exec.vu.idInTest / orgs),
    admin: { token: pick(org.adminTokens), org: org.id },
    member: { token: pick(org.memberTokens), org: org.id },
  };
}

const subscriptionPath = '/webhook-subscriptions/{subscriptionID}';
const deliveryPath = '/webhook-deliveries/{deliveryID}';
const eventPath = '/webhook-events/{eventID}';

function createSubscription(c) {
  return prep(200, 'POST', '/webhook-subscriptions', {
    ...c.admin,
    body: { name: `Load ${uniqueCode()}`, url: 'https://loadtest-scenario.invalid/hook', eventTypes: COMPANY_EVENTS, companyIds: [] },
  });
}

function deleteSubscription(c, id) {
  prep(204, 'DELETE', `/webhook-subscriptions/${id}`, { ...c.admin, name: subscriptionPath });
}

function createCompany(c) {
  return prep(200, 'POST', '/companies', { ...c.admin, body: { code: uniqueCode(), name: 'Load test company' } });
}

// `requests` counts every request an iteration sends, setup and cleanup included, so a step's
// rate is what the API receives. `lowFrequency` writes run at `steps.lowFrequencyRates`: they
// serialize per organization by design (the subscription cap) and are rare in real traffic.
export const routes = [
  // Users
  { key: 'users_list', method: 'GET', path: '/users', run: (c) => measured(200, 'GET', '/users', { ...c.member, name: '/users' }) },
  { key: 'users_list_email', method: 'GET', path: '/users', run: (c) => measured(200, 'GET', '/users?email=member', { ...c.member, name: '/users?email' }) },
  { key: 'users_get', method: 'GET', path: '/users/{userID}', run: (c) => measured(200, 'GET', `/users/${pick(c.org.userIds)}`, { ...c.member, name: '/users/{userID}' }) },
  { key: 'me_get', method: 'GET', path: '/me', run: (c) => measured(200, 'GET', '/me', { token: c.member.token }) },
  { key: 'me_patch', method: 'PATCH', path: '/me', write: true, run: (c) => measured(200, 'PATCH', '/me', { token: c.member.token, body: { firstName: `Member${exec.vu.iterationInInstance % 100}` } }) },
  { key: 'me_access', method: 'GET', path: '/me/access', run: (c) => measured(200, 'GET', '/me/access', c.member) },
  { key: 'me_organizations', method: 'GET', path: '/me/organizations', run: (c) => measured(200, 'GET', '/me/organizations', { token: c.member.token, name: '/me/organizations' }) },

  // Companies
  { key: 'companies_list', method: 'GET', path: '/companies', run: (c) => measured(200, 'GET', '/companies', { ...c.member, name: '/companies' }) },
  { key: 'companies_list_name', method: 'GET', path: '/companies', run: (c) => measured(200, 'GET', '/companies?name=company%201', { ...c.member, name: '/companies?name' }) },
  {
    key: 'companies_create', method: 'POST', path: '/companies', write: true, requests: 2,
    run: (c) => {
      const res = measured(200, 'POST', '/companies', { ...c.admin, body: { code: uniqueCode(), name: 'Load test company' } });
      // Cleanup keeps the dataset the same size for later scenarios.
      if (res.status === 200) prep(204, 'DELETE', `/companies/${res.json('id')}`, { ...c.admin, name: '/companies/{companyID}' });
    },
  },
  { key: 'companies_get', method: 'GET', path: '/companies/{companyID}', run: (c) => measured(200, 'GET', `/companies/${pick(c.org.companies)}`, { ...c.member, name: '/companies/{companyID}' }) },
  {
    key: 'companies_patch', method: 'PATCH', path: '/companies/{companyID}', write: true,
    run: (c) => measured(200, 'PATCH', `/companies/${c.org.companies[c.slot % c.org.companies.length]}`, { ...c.admin, name: '/companies/{companyID}', body: { name: `Load company ${exec.vu.iterationInInstance % 1000}` } }),
  },
  {
    key: 'companies_delete', method: 'DELETE', path: '/companies/{companyID}', write: true, requests: 2,
    run: (c) => {
      const created = createCompany(c);
      if (created) measured(204, 'DELETE', `/companies/${created.json('id')}`, { ...c.admin, name: '/companies/{companyID}' });
    },
  },

  // Webhook subscriptions. Writes clean up after themselves: each organization allows at most 100.
  {
    key: 'webhook_subscriptions_create', method: 'POST', path: '/webhook-subscriptions', write: true, requests: 2, lowFrequency: true,
    run: (c) => {
      const res = measured(200, 'POST', '/webhook-subscriptions', {
        ...c.admin,
        body: { name: `Load ${uniqueCode()}`, url: 'https://loadtest-scenario.invalid/hook', eventTypes: COMPANY_EVENTS, companyIds: [] },
      });
      if (res.status === 200) deleteSubscription(c, res.json('id'));
    },
  },
  { key: 'webhook_subscriptions_list', method: 'GET', path: '/webhook-subscriptions', run: (c) => measured(200, 'GET', '/webhook-subscriptions', { ...c.member, name: '/webhook-subscriptions' }) },
  { key: 'webhook_subscriptions_list_event_type', method: 'GET', path: '/webhook-subscriptions', run: (c) => measured(200, 'GET', '/webhook-subscriptions?eventType=company.updated', { ...c.member, name: '/webhook-subscriptions?eventType' }) },
  { key: 'webhook_subscriptions_get', method: 'GET', path: subscriptionPath, run: (c) => measured(200, 'GET', `/webhook-subscriptions/${pick(c.org.subscriptions)}`, { ...c.member, name: subscriptionPath }) },
  { key: 'webhook_subscriptions_versions', method: 'GET', path: `${subscriptionPath}/versions`, run: (c) => measured(200, 'GET', `/webhook-subscriptions/${pick(c.org.subscriptions)}/versions`, { ...c.member, name: `${subscriptionPath}/versions` }) },
  {
    key: 'webhook_subscriptions_patch', method: 'PATCH', path: subscriptionPath, write: true, requests: 3, lowFrequency: true,
    run: (c) => {
      const created = createSubscription(c);
      if (!created) return;
      const id = created.json('id');
      measured(200, 'PATCH', `/webhook-subscriptions/${id}`, { ...c.admin, name: subscriptionPath, body: { expectedRevisionId: created.json('currentRevisionId'), name: `Renamed ${uniqueCode()}` } });
      deleteSubscription(c, id);
    },
  },
  {
    key: 'webhook_subscriptions_delete', method: 'DELETE', path: subscriptionPath, write: true, requests: 2, lowFrequency: true,
    run: (c) => {
      const created = createSubscription(c);
      if (created) measured(204, 'DELETE', `/webhook-subscriptions/${created.json('id')}`, { ...c.admin, name: subscriptionPath });
    },
  },
  {
    key: 'webhook_subscriptions_disable', method: 'POST', path: `${subscriptionPath}/disable`, write: true, requests: 3, lowFrequency: true,
    run: (c) => {
      const created = createSubscription(c);
      if (!created) return;
      const id = created.json('id');
      measured(204, 'POST', `/webhook-subscriptions/${id}/disable`, { ...c.admin, name: `${subscriptionPath}/disable` });
      deleteSubscription(c, id);
    },
  },
  // The response holds a signing secret; nothing reads or reports its body.
  { key: 'webhook_subscriptions_secret', method: 'POST', path: `${subscriptionPath}/secret`, write: true, run: (c) => { measured(200, 'POST', `/webhook-subscriptions/${pick(c.org.subscriptions)}/secret`, { ...c.admin, name: `${subscriptionPath}/secret` }); } },
  { key: 'webhook_subscriptions_health', method: 'GET', path: `${subscriptionPath}/health`, run: (c) => measured(200, 'GET', `/webhook-subscriptions/${pick(c.org.subscriptions)}/health`, { ...c.member, name: `${subscriptionPath}/health` }) },

  // Webhook deliveries and events
  { key: 'webhook_deliveries_list', method: 'GET', path: '/webhook-deliveries', run: (c) => measured(200, 'GET', '/webhook-deliveries', { ...c.member, name: '/webhook-deliveries' }) },
  { key: 'webhook_deliveries_list_state', method: 'GET', path: '/webhook-deliveries', run: (c) => measured(200, 'GET', '/webhook-deliveries?state=retrying', { ...c.member, name: '/webhook-deliveries?state' }) },
  { key: 'webhook_deliveries_get', method: 'GET', path: deliveryPath, run: (c) => measured(200, 'GET', `/webhook-deliveries/${pick(c.org.deliveries)}`, { ...c.member, name: deliveryPath }) },
  { key: 'webhook_deliveries_attempts', method: 'GET', path: `${deliveryPath}/attempts`, run: (c) => measured(200, 'GET', `/webhook-deliveries/${pick(c.org.deliveries)}/attempts`, { ...c.member, name: `${deliveryPath}/attempts` }) },
  { key: 'webhook_deliveries_attempts_outcome', method: 'GET', path: `${deliveryPath}/attempts`, run: (c) => measured(200, 'GET', `/webhook-deliveries/${pick(c.org.deliveries)}/attempts?outcome=retryable`, { ...c.member, name: `${deliveryPath}/attempts?outcome` }) },
  { key: 'webhook_deliveries_payload', method: 'GET', path: `${deliveryPath}/payload`, run: (c) => measured(200, 'GET', `/webhook-deliveries/${pick(c.org.deliveries)}/payload`, { ...c.admin, name: `${deliveryPath}/payload` }) },
  { key: 'webhook_event_types', method: 'GET', path: '/webhook-event-types', run: (c) => measured(200, 'GET', '/webhook-event-types', { ...c.member, name: '/webhook-event-types' }) },
  { key: 'webhook_events_list', method: 'GET', path: '/webhook-events', run: (c) => measured(200, 'GET', '/webhook-events', { ...c.member, name: '/webhook-events' }) },
  // Full pages cost about 10 ms of app CPU each; kept as a variant to track list serialization.
  { key: 'webhook_events_list_per100', method: 'GET', path: '/webhook-events', run: (c) => measured(200, 'GET', '/webhook-events?per=100', { ...c.member, name: '/webhook-events?per=100' }) },
  { key: 'webhook_events_list_type', method: 'GET', path: '/webhook-events', run: (c) => measured(200, 'GET', '/webhook-events?type=company.updated', { ...c.member, name: '/webhook-events?type' }) },
  { key: 'webhook_events_get', method: 'GET', path: eventPath, run: (c) => measured(200, 'GET', `/webhook-events/${pick(c.org.events)}`, { ...c.member, name: eventPath }) },
  { key: 'webhook_events_payload', method: 'GET', path: `${eventPath}/payload`, run: (c) => measured(200, 'GET', `/webhook-events/${pick(c.org.events)}/payload`, { ...c.admin, name: `${eventPath}/payload` }) },
];

export const routesByKey = Object.fromEntries(routes.map((r) => [r.key, r]));

/** Route groups the coverage check holds the registry to. */
export const COVERED_PREFIXES = ['/users', '/me', '/companies', '/webhook-'];

/** Returns "METHOD /path" entries in the OpenAPI document that have no scenario. */
export function uncoveredRoutes(openapi) {
  const covered = new Set(routes.map((r) => `${r.method} ${r.path}`));
  const missing = [];
  for (const [path, operations] of Object.entries(openapi.paths || {})) {
    if (!COVERED_PREFIXES.some((prefix) => path.startsWith(prefix))) continue;
    for (const method of Object.keys(operations)) {
      const route = `${method.toUpperCase()} ${path}`;
      if (['GET', 'POST', 'PUT', 'PATCH', 'DELETE'].includes(method.toUpperCase()) && !covered.has(route)) missing.push(route);
    }
  }
  return missing.sort();
}
