import type { NextRequest } from 'next/server';
import { exchangeCredentials } from '@/lib/server/password-auth';

export function POST(request: NextRequest) {
  return exchangeCredentials(request, '/api/auth/login');
}
