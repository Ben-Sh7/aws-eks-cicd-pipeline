import { Injectable } from '@nestjs/common';
import { collectDefaultMetrics, Histogram, Registry } from '@prometheus-io/client';

@Injectable()
export class MetricsService {
  private readonly registry = new Registry();

  readonly requestDuration = new Histogram({
    name: 'http_request_duration_seconds',
    help: 'Time spent handling an HTTP request, by route and outcome',
    labelNames: ['method', 'route', 'status'] as const,
    buckets: [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5],
    registers: [this.registry],
  });

  constructor() {
    collectDefaultMetrics({ register: this.registry });
  }

  get contentType(): string {
    return this.registry.contentType;
  }

  render(): Promise<string> {
    return this.registry.metrics();
  }
}
