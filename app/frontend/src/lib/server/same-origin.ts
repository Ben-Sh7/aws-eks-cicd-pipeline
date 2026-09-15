import type { NextRequest } from 'next/server';
import { serverEnv } from './env';

// CSRF defence in depth on top of SameSite=Lax cookies: a state-changing
// request must come from this app's own pages. Browsers send Origin on every
// POST/PATCH/DELETE; Sec-Fetch-Site covers the rare case where it is absent.
export function isSameOrigin(request: NextRequest): boolean {
  const origin = request.headers.get('origin');
  if (origin !== null) {
    return origin === serverEnv().appUrl;
  }
  return request.headers.get('sec-fetch-site') === 'same-origin';
}
