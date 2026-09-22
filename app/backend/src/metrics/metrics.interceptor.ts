import {
  CallHandler,
  ExecutionContext,
  Injectable,
  NestInterceptor,
} from '@nestjs/common';
import type { Request, Response } from 'express';
import { Observable, tap } from 'rxjs';
import { MetricsService } from './metrics.service';

@Injectable()
export class MetricsInterceptor implements NestInterceptor {
  constructor(private readonly metrics: MetricsService) {}

  intercept(context: ExecutionContext, next: CallHandler): Observable<unknown> {
    const http = context.switchToHttp();
    const request = http.getRequest<Request>();
    const stop = this.metrics.requestDuration.startTimer();

    const record = (status: number): void => {
      stop({
        method: request.method,
        // The declared path, not the URL: /tasks/:id stays one series
        // instead of one per task id.
        route: request.route?.path ?? 'unmatched',
        status: String(status),
      });
    };

    return next.handle().pipe(
      tap({
        next: () => record(http.getResponse<Response>().statusCode),
        error: (err: { status?: number }) => record(err?.status ?? 500),
      }),
    );
  }
}
