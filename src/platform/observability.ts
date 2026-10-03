import { randomUUID } from 'node:crypto';
import { RequestHandler } from 'express';
import {
  collectDefaultMetrics,
  Counter,
  Histogram,
  Registry,
} from 'prom-client';

export const registry = new Registry();
registry.setDefaultLabels({ app: 'realworld-api' });
collectDefaultMetrics({ register: registry });

const requests = new Counter({
  name: 'http_requests_total',
  help: 'Total completed HTTP requests',
  labelNames: ['method', 'route', 'status_code'],
  registers: [registry],
});

const duration = new Histogram({
  name: 'http_request_duration_seconds',
  help: 'HTTP request duration in seconds',
  labelNames: ['method', 'route', 'status_code'],
  buckets: [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2, 5],
  registers: [registry],
});

export function log(
  level: string,
  event: string,
  fields: Record<string, unknown> = {},
): void {
  console.log(JSON.stringify({
    timestamp: new Date().toISOString(),
    level,
    event,
    ...fields,
  }));
}

export const observeHttp: RequestHandler = (req, res, next) => {
  const started = process.hrtime.bigint();
  const requestId = randomUUID();
  res.setHeader('X-Request-ID', requestId);

  res.once('finish', () => {
    // Route templates avoid labels containing IDs, slugs or query strings.
    const route = typeof req.route?.path === 'string'
      ? req.route.path
      : 'unmatched';

    // Probes and scrapes should not inflate business traffic metrics.
    if (route.startsWith('/health/') || route === '/metrics') return;

    const seconds = Number(process.hrtime.bigint() - started) / 1e9;
    const labels = {
      method: req.method,
      route,
      status_code: String(res.statusCode),
    };

    requests.inc(labels);
    duration.observe(labels, seconds);

    // Never record bodies, authorization headers or query strings.
    log(res.statusCode >= 500 ? 'error' : 'info', 'http_request', {
      request_id: requestId,
      ...labels,
      duration_ms: Math.round(seconds * 1000),
    });
  });

  next();
};
