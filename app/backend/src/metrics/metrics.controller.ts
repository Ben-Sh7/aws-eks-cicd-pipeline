import { Controller, Get, Header } from '@nestjs/common';
import { Public } from '../auth/public.decorator';
import { MetricsService } from './metrics.service';

// Reachable only from inside the cluster: the backend Service is ClusterIP and
// the frontend forwards a fixed list of routes that does not include this one.
@Controller('metrics')
export class MetricsController {
  constructor(private readonly metrics: MetricsService) {}

  @Public()
  @Get()
  @Header('Cache-Control', 'no-store')
  async scrape(): Promise<string> {
    return this.metrics.render();
  }
}
