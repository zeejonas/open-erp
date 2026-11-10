// Turns the route registry into sequential step scenarios. Each step is its own
// constant-arrival-rate scenario: k6 keeps sending at the target rate however slowly the
// server answers, so saturation shows up as latency, errors and dropped iterations.

export function seconds(duration) {
  const match = /^(\d+)(s|m)$/.exec(duration);
  if (!match) throw new Error(`Unsupported duration ${duration}; use e.g. 30s or 2m`);
  return Number(match[1]) * (match[2] === 'm' ? 60 : 1);
}

export function stepName(key, rate) {
  return `${key}__${rate}`;
}

/** The thresholds a step must meet. handleSummary reads their verdicts. */
export function stepThresholds(name, budgetMs, target) {
  return {
    [`http_req_duration{scenario:${name},measured:true}`]: [`p(95)<${budgetMs}`],
    [`errors{scenario:${name}}`]: ['rate<0.01'],
    [`iterations{scenario:${name}}`]: [`count>=${Math.ceil(target * 0.95)}`],
  };
}

/** Enough VUs up front for responses up to 250 ms; k6 adds more up to `maxVUs`. */
function preAllocated(rate, maxVUs) {
  return Math.min(maxVUs, Math.max(2, Math.ceil(rate / 4)));
}

/**
 * Lays out one scenario per route and step, one after another, plus the mixed workload and
 * the isolation stream that runs for the whole test. Reads run before writes so write
 * scenarios don't grow the tables reads measure. Returns k6 `scenarios`, `thresholds` and
 * the timeline the report uses to line up pg samples.
 */
export function buildPlan(routes, config) {
  const { maxVUs } = config.steps;
  const step = seconds(config.steps.duration);
  const pause = seconds(config.steps.pause);
  const scenarios = {};
  const thresholds = {};
  const timeline = [];
  let offset = 0;

  const ordered = [...routes.filter((r) => !r.write), ...routes.filter((r) => r.write)];
  for (const route of ordered) {
    const rates = route.lowFrequency ? config.steps.lowFrequencyRates : config.steps.rates;
    const requests = route.requests || 1;
    rates.forEach((rate, i) => {
      const name = stepName(route.key, rate);
      const budget = route.write ? config.budgets.writeP95Ms : config.budgets.readP95Ms;
      const target = Math.floor((rate * step) / requests);
      scenarios[name] = {
        executor: 'constant-arrival-rate',
        exec: 'run',
        // `rate` iterations per `requests` seconds, so the API receives `rate` requests a second.
        rate,
        timeUnit: `${requests}s`,
        duration: `${step}s`,
        preAllocatedVUs: preAllocated(rate, maxVUs),
        maxVUs,
        startTime: `${offset}s`,
        gracefulStop: '5s',
        tags: { route: route.key },
      };
      Object.assign(thresholds, stepThresholds(name, budget, target));
      timeline.push({ name, route: route.key, rate, index: i, budget, target, start: offset, end: offset + step });
      offset += step + 5;
    });
    offset += pause;
  }

  const mixed = config.mixed;
  const mixedDuration = seconds(mixed.duration);
  scenarios.mixed = {
    executor: 'constant-arrival-rate',
    exec: 'mixed',
    rate: mixed.rate,
    timeUnit: '1s',
    duration: `${mixedDuration}s`,
    preAllocatedVUs: preAllocated(mixed.rate, maxVUs),
    maxVUs,
    startTime: `${offset}s`,
    gracefulStop: '5s',
  };
  Object.assign(thresholds, stepThresholds('mixed', config.budgets.writeP95Ms, mixed.rate * mixedDuration));
  timeline.push({ name: 'mixed', route: 'mixed', rate: mixed.rate, budget: config.budgets.writeP95Ms, target: mixed.rate * mixedDuration, start: offset, end: offset + mixedDuration });
  offset += mixedDuration;

  scenarios.isolation = {
    executor: 'constant-arrival-rate',
    exec: 'isolation',
    rate: config.isolation.rate,
    timeUnit: '1s',
    duration: `${offset}s`,
    preAllocatedVUs: 5,
    maxVUs: 50,
    gracefulStop: '5s',
  };
  thresholds.isolation_failures = ['count==0'];

  return { scenarios, thresholds, timeline, totalSeconds: offset };
}
