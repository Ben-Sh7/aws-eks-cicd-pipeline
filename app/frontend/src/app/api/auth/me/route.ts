import type { NextRequest } from 'next/server';
import { forwardToBackend } from '@/lib/server/bff';

export function GET(request: NextRequest) {
  return forwardToBackend(request, '/api/auth/me', 'GET');
}
