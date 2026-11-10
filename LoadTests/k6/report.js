// Turns /out/results.json and the pg sampler's /out/pg-samples.csv into report.json and
// report.md. It also decides the run's verdict: an isolation failure fails the run,
// saturation does not. Runs as a single k6 iteration, so the host needs only Docker.
import { Counter } from 'k6/metrics';

const results = JSON.parse(open('/out/results.json'));
const samples = open('/out/pg-samples.csv')
  .split('\n')
  .filter((line) => line.trim())
  .map((line) => line.split(',').map(Number));

const runFailures = new Counter('run_failures');

export const options = {
  vus: 1,
  iterations: 1,
  thresholds: { run_failures: ['count==0'] },
};

const meta = {
  gitCommit: __ENV.GIT_SHA,
  hostCpus: Number(__ENV.HOST_CPUS),
  appCpus: __ENV.APP_CPUS,
  appMemory: __ENV.APP_MEMORY,
  dbCpus: __ENV.DB_CPUS,
  k6Cpus: __ENV.K6_CPUS,
  eventLoops: Math.ceil(Number(__ENV.APP_CPUS)),
  maxConnectionsPerEventLoop: Number(__ENV.DATABASE_MAX_CONNECTIONS_PER_EVENT_LOOP),
  databaseTlsMode: 'disable',
};
meta.poolCeiling = meta.eventLoops * meta.maxConnectionsPerEventLoop;

/** Peak runtime-role connections sampled while a step ran. */
function peakConnections(step) {
  if (!results.startedAt) return null;
  const from = results.startedAt / 1000 + step.start;
  const to = results.startedAt / 1000 + step.end;
  const inWindow = samples.filter(([t]) => t >= from && t <= to).map(([, count]) => count);
  return inWindow.length ? Math.max(...inWindow) : null;
}

function verdict(step) {
  if (step.latencyOk && step.errorsOk && step.sentOk) return 'pass';
  // k6 fell behind while the API stayed inside budget: the generator, not the API, saturated.
  if (step.latencyOk && step.errorsOk) return 'generator-bound';
  return 'fail';
}

const steps = results.steps.map((step) => ({ ...step, verdict: verdict(step), peakConnections: peakConnections(step) }));

const endpoints = results.routes.map((route) => {
  const routeSteps = steps.filter((s) => s.route === route.key).sort((a, b) => a.rate - b.rate);
  const firstStop = routeSteps.findIndex((s) => s.verdict !== 'pass');
  const passed = firstStop === -1 ? routeSteps : routeSteps.slice(0, firstStop);
  const stop = firstStop === -1 ? null : routeSteps[firstStop];
  const top = passed.length ? passed[passed.length - 1].rate : 0;
  const peaks = routeSteps.map((s) => s.peakConnections).filter((p) => p !== null);
  return {
    ...route,
    supportedRps: top,
    lowerBound: stop === null || stop.verdict === 'generator-bound',
    firstFailingStep: stop && stop.verdict === 'fail' ? stop.rate : null,
    generatorBoundStep: stop && stop.verdict === 'generator-bound' ? stop.rate : null,
    peakConnections: peaks.length ? Math.max(...peaks) : null,
    steps: routeSteps.map(({ rate, p50, p95, p99, errorRate, sent, target, budget, verdict, peakConnections }) =>
      ({ rate, p50, p95, p99, errorRate, sent, target, budget, verdict, peakConnections })),
  };
});

const mixed = steps.find((s) => s.route === 'mixed');
const allPeaks = samples.map(([, count]) => count);
// Secret disclosures by anyone outside the administrators group, counted in the database by run.sh.
const isolation = { ...results.isolation, unauthorizedReveals: Number(__ENV.UNAUTHORIZED_REVEALS) };
const isolationFailed = isolation.failures > 0 || isolation.checks === 0 || isolation.unauthorizedReveals !== 0;

const report = {
  meta,
  dataset: results.dataset,
  stepPlan: results.config.steps,
  budgets: results.config.budgets,
  peakConnections: allPeaks.length ? Math.max(...allPeaks) : null,
  isolation: { ...isolation, passed: !isolationFailed },
  endpoints,
  mixed: mixed && { rate: mixed.rate, p50: mixed.p50, p95: mixed.p95, p99: mixed.p99, errorRate: mixed.errorRate, sent: mixed.sent, target: mixed.target, verdict: mixed.verdict, peakConnections: mixed.peakConnections, weights: results.config.mixed.weights },
};

const ms = (v) => (v === null || v === undefined ? '–' : `${v.toFixed(1)}`);
const pct = (v) => `${(v * 100).toFixed(2)}%`;
const supported = (e) => `${e.lowerBound ? '≥ ' : ''}${e.supportedRps}${e.supportedRps === 0 && !e.lowerBound ? ' (failed first step)' : ''}`;

function markdown() {
  const lines = [
    '# Load test report',
    '',
    '| Setting | Value |',
    '| --- | --- |',
    `| Git commit | \`${meta.gitCommit}\` |`,
    `| Host CPUs | ${meta.hostCpus} |`,
    `| App limits | ${meta.appCpus} CPUs, ${meta.appMemory} memory (${meta.eventLoops} event loops) |`,
    `| Database / k6 CPUs | ${meta.dbCpus} / ${meta.k6Cpus} |`,
    `| Pool | ${meta.maxConnectionsPerEventLoop} per event loop, ceiling ${meta.poolCeiling} |`,
    `| Database TLS | ${meta.databaseTlsMode} |`,
    `| Peak runtime-role connections | ${report.peakConnections ?? '–'} |`,
    `| Dataset | ${Object.entries(report.dataset).map(([k, v]) => `${k} ${v}`).join(', ')} |`,
    `| Steps | ${report.stepPlan.rates.join(', ')} RPS (low-frequency writes ${report.stepPlan.lowFrequencyRates.join(', ')}) × ${report.stepPlan.duration}; p95 budget ${report.budgets.readP95Ms} ms read, ${report.budgets.writeP95Ms} ms write |`,
    `| Isolation checks | ${isolation.checks} sent, ${isolation.failures} failed, ${isolation.unauthorizedReveals} unauthorized secret disclosures — ${isolationFailed ? '**FAILED**' : 'passed'} |`,
    '',
    '## Supported RPS',
    '',
    'Highest passing step before the first failing one. "≥" means no step failed, so the figure is a lower bound. RPS counts every request a scenario sends, including setup and cleanup (the Requests column); latency covers only the named route. Sent / target counts iterations.',
    '',
    '| Scenario | Route | Requests | Supported RPS | First failing step | Peak connections |',
    '| --- | --- | --- | --- | --- | --- |',
    ...endpoints.map((e) => `| ${e.key} | \`${e.method} ${e.path}\` | ${e.requests} | ${supported(e)} | ${e.firstFailingStep ?? (e.generatorBoundStep ? `${e.generatorBoundStep} (generator-bound)` : '–')} | ${e.peakConnections ?? '–'} |`),
  ];
  if (mixed) {
    lines.push('', '## Mixed workload', '',
      `${mixed.rate} RPS: p50 ${ms(mixed.p50)} ms, p95 ${ms(mixed.p95)} ms, p99 ${ms(mixed.p99)} ms, errors ${pct(mixed.errorRate)}, sent ${mixed.sent}/${mixed.target} — **${mixed.verdict}**`);
  }
  lines.push('', '## Steps', '');
  for (const e of endpoints) {
    lines.push(`### ${e.key} — \`${e.method} ${e.path}\``, '',
      '| RPS | p50 ms | p95 ms | p99 ms | Errors | Sent / target | Peak conns | Verdict |',
      '| --- | --- | --- | --- | --- | --- | --- | --- |',
      ...e.steps.map((s) => `| ${s.rate} | ${ms(s.p50)} | ${ms(s.p95)} | ${ms(s.p99)} | ${pct(s.errorRate)} | ${s.sent} / ${s.target} | ${s.peakConnections ?? '–'} | ${s.verdict} |`),
      '');
  }
  return lines.join('\n');
}

export default function () {
  if (isolationFailed) runFailures.add(1);
}

export function handleSummary() {
  const md = markdown();
  return {
    '/out/report.json': JSON.stringify(report, null, 2),
    '/out/report.md': md,
    stdout: `${md.split('## Steps')[0]}\n`,
  };
}
