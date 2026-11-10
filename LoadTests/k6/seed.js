// Seeds the harness database through the public API only, so RBAC, audit triggers and event
// production run as they do in production. run.sh creates the platform administrator with the
// CLI first. The seed (IDs and subjects, no tokens) goes to /out/seed.json for scenarios.js.
import { mint, must, mustBatch, req, waitForHealth } from './lib/api.js';

const config = JSON.parse(open('/config/config.json'));
const size = config.dataset;
const PLATFORM_SUBJECT = __ENV.PLATFORM_SUBJECT;
const PLATFORM_EMAIL = __ENV.PLATFORM_EMAIL;
const COMPANY_EVENTS = ['company.created', 'company.updated', 'company.deleted'];

export const options = {
  vus: 1,
  iterations: 1,
  setupTimeout: '60m',
  summaryTrendStats: ['med'],
};

function person(org, role, n) {
  const sub = `loadtest-org${org}-${role}-${n}`;
  return { sub, email: `${sub}@loadtest.example.com`, firstName: `${role}${n}`, lastName: `Org${org}` };
}

function accept(person, invitationToken) {
  const token = mint(person.sub, person.email);
  const res = must(200, 'POST', '/invitations/accept', { token, body: { token: invitationToken } });
  return { sub: person.sub, email: person.email, userId: res.json('user.id') };
}

function invite(org, adminToken, people, groupId) {
  const responses = mustBatch(200, people.map((p) => req('POST', '/organization-invitations', {
    token: adminToken, org,
    body: { email: p.email, firstName: p.firstName, lastName: p.lastName, groupId },
  })));
  return people.map((p, i) => accept(p, responses[i].json('token')));
}

function seedOrganization(platformToken, index) {
  const owner = person(index, 'admin', 0);
  const provisioned = must(200, 'POST', '/platform/organizations', {
    token: platformToken,
    body: {
      code: `LOADT${index}`, name: `Load test organization ${index}`,
      adminEmail: owner.email, adminFirstName: owner.firstName, adminLastName: owner.lastName,
    },
  });
  const org = provisioned.json('organization.id');
  const admins = [accept(owner, provisioned.json('invitationToken'))];
  const adminToken = mint(owner.sub, owner.email);

  const groups = must(200, 'GET', '/groups?per=100', { token: adminToken, org }).json('items');
  const groupId = (key) => groups.find((g) => g.templateKey === key).id;
  const extraAdmins = Array.from({ length: size.adminsPerOrganization - 1 }, (_, n) => person(index, 'admin', n + 1));
  admins.push(...invite(org, adminToken, extraAdmins, groupId('org_admins')));
  const viewers = Array.from({ length: size.membersPerOrganization }, (_, n) => person(index, 'member', n));
  const members = invite(org, adminToken, viewers, groupId('org_viewers'));

  const companies = mustBatch(200, Array.from({ length: size.companiesPerOrganization }, (_, n) => req('POST', '/companies', {
    token: adminToken, org, name: '/companies',
    body: { code: `C${index}N${n}`, name: `Seed company ${index}-${n}` },
  }))).map((res) => res.json('id'));

  const watched = companies.slice(0, size.companiesPerEnabledSubscription);
  const subscriptions = [];
  for (let s = 0; s < size.subscriptionsPerOrganization; s++) {
    const enabled = s < size.enabledSubscriptionsPerOrganization;
    const created = must(200, 'POST', '/webhook-subscriptions', {
      token: adminToken, org,
      body: {
        name: `Seed subscription ${s}`,
        // RFC 6761 reserves .invalid, so these never resolve.
        url: `https://loadtest-${index}-${s}.invalid/hook`,
        eventTypes: COMPANY_EVENTS,
        companyIds: enabled ? watched : [],
      },
    });
    const id = created.json('id');
    if (enabled) {
      must(200, 'PATCH', `/webhook-subscriptions/${id}`, {
        token: adminToken, org, name: '/webhook-subscriptions/{subscriptionID}',
        body: { expectedRevisionId: created.json('currentRevisionId'), enabled: true },
      });
    }
    subscriptions.push(id);
  }

  // Updates after the subscriptions exist produce events that fan out to deliveries.
  for (let round = 1; round <= size.companyUpdatesPerCompany; round++) {
    mustBatch(200, companies.map((id, n) => req('PATCH', `/companies/${id}`, {
      token: adminToken, org, name: '/companies/{companyID}',
      body: { name: `Seed company ${index}-${n} r${round}` },
    })));
  }

  return { id: org, code: `LOADT${index}`, admins, members, companies, subscriptions };
}

export function setup() {
  if (size.organizations < 2) throw new Error('dataset.organizations must be at least 2 for isolation checks');
  waitForHealth();
  const platformToken = mint(PLATFORM_SUBJECT, PLATFORM_EMAIL);
  const organizations = [];
  for (let i = 0; i < size.organizations; i++) organizations.push(seedOrganization(platformToken, i));
  return { organizations, dataset: size };
}

export default function () {}

export function handleSummary(data) {
  return { '/out/seed.json': JSON.stringify(data.setup_data) };
}
