import express from 'express';
import cors from 'cors';
import * as bodyParser from 'body-parser';
import routes from './app/routes/routes';
import HttpException from './app/models/http-exception.model';
import prisma from './prisma/prisma-client';
import { log, observeHttp, registry } from './platform/observability';

const app = express();
let shuttingDown = false;

app.disable('x-powered-by');
app.use(observeHttp);
app.use(cors());
app.use(bodyParser.json());
app.use(bodyParser.urlencoded({ extended: true }));

app.get('/health/live', (_req, res) => {
  res.status(200).json({ status: 'alive' });
});

app.get('/health/ready', async (_req, res) => {
  if (shuttingDown) {
    res.status(503).json({ status: 'shutting_down' });
    return;
  }

  let timer: ReturnType<typeof setTimeout> | undefined;
  try {
    // Bound probe duration; the timeout does not cancel the database query.
    await Promise.race([
      prisma.$queryRaw`SELECT 1`,
      new Promise<never>((_resolve, reject) => {
        timer = setTimeout(() => reject(new Error('probe timeout')), 2000);
      }),
    ]);
    res.status(shuttingDown ? 503 : 200).json({
      status: shuttingDown ? 'shutting_down' : 'ready',
    });
  } catch {
    res.status(503).json({ status: 'not_ready' });
  } finally {
    if (timer) clearTimeout(timer);
  }
});

app.get('/metrics', async (_req, res, next) => {
  try {
    res.setHeader('Content-Type', registry.contentType);
    res.end(await registry.metrics());
  } catch (error) {
    next(error);
  }
});

app.use(routes);
app.use(express.static(__dirname + '/assets'));

app.get('/', (_req, res) => {
  res.json({ status: 'API is running on /api' });
});

app.use((
  err: Error | HttpException,
  _req: express.Request,
  res: express.Response,
  next: express.NextFunction,
) => {
  if (res.headersSent) {
    next(err);
    return;
  }

  const errorCode = (err as Error & { errorCode?: number }).errorCode;
  if (err.name === 'UnauthorizedError') {
    res.status(401).json({
      status: 'error',
      message: 'missing authorization credentials',
    });
  } else if (errorCode) {
    res.status(errorCode).json(err.message);
  } else {
    // Avoid exposing internal errors or credentials in responses and logs.
    res.status(500).json({ status: 'error', message: 'internal server error' });
  }
});

const port = Number(process.env.PORT || 3000);
const host = process.env.HOST || '0.0.0.0';

const server = app.listen(port, host, () => {
  log('info', 'server_started', { port, host });
});

function shutdown(signal: string): void {
  if (shuttingDown) return;
  shuttingDown = true;
  log('info', 'shutdown_started', { signal });

  const deadline = setTimeout(() => {
    log('error', 'shutdown_timeout');
    process.exit(1);
  }, 10000);
  deadline.unref();

  // Stop accepting connections and let active requests complete.
  server.close(async (error) => {
    try {
      await prisma.$disconnect();
      clearTimeout(deadline);
      log(error ? 'error' : 'info', 'shutdown_completed');
      process.exit(error ? 1 : 0);
    } catch {
      log('error', 'shutdown_failed');
      process.exit(1);
    }
  });
}

process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('SIGINT', () => shutdown('SIGINT'));
