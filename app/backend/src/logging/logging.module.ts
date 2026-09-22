import { Module } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { LoggerModule } from 'nestjs-pino';
import { randomUUID } from 'node:crypto';
import type { Env } from '../config/env.validation';

// Anything here is replaced with [redacted] before a line is written. A token
// or a password in a log file is a leak that outlives the request.
const REDACTED = [
  'req.headers.authorization',
  'req.headers.cookie',
  'req.body.password',
  'req.body.currentPassword',
  'req.body.newPassword',
  'req.body.refreshToken',
  'req.body.idToken',
  'res.headers["set-cookie"]',
];

@Module({
  imports: [
    LoggerModule.forRootAsync({
      inject: [ConfigService],
      useFactory: (config: ConfigService<Env, true>) => ({
        pinoHttp: {
          level: config.get('LOG_LEVEL', { infer: true }),
          redact: { paths: REDACTED, censor: '[redacted]' },

          // One id per request, on every line the request produces, so a single
          // failure can be followed across them.
          genReqId: (req, res) => {
            const existing = req.headers['x-request-id'];
            const id = typeof existing === 'string' ? existing : randomUUID();
            res.setHeader('x-request-id', id);
            return id;
          },

          customLogLevel: (_req, res, err) => {
            if (err || res.statusCode >= 500) return 'error';
            if (res.statusCode >= 400) return 'warn';
            return 'info';
          },

          // The probes run every few seconds and say nothing when they pass.
          autoLogging: {
            ignore: (req) => req.url === '/health' || req.url === '/metrics',
          },

          serializers: {
            req: (req: { method: string; url: string; id: string }) => ({
              id: req.id,
              method: req.method,
              url: req.url,
            }),
            res: (res: { statusCode: number }) => ({
              statusCode: res.statusCode,
            }),
          },
        },
      }),
    }),
  ],
})
export class LoggingModule {}
