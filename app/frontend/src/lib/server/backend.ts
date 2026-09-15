import { serverEnv } from './env';

export interface AuthTokens {
  accessToken: string;
  accessTokenExpiresIn: number;
  refreshToken: string;
  refreshTokenExpiresIn: number;
}

interface BackendRequest {
  method: 'GET' | 'POST' | 'PATCH' | 'DELETE';
  body?: string;
  accessToken?: string;
  /** The incoming X-Forwarded-For chain, so the backend rate-limits per browser. */
  forwardedFor?: string | null;
}

const BACKEND_TIMEOUT_MS = 10_000;

export function backendFetch(
  path: string,
  { method, body, accessToken, forwardedFor }: BackendRequest,
): Promise<Response> {
  const headers = new Headers({ Accept: 'application/json' });
  if (body !== undefined) {
    headers.set('Content-Type', 'application/json');
  }
  if (accessToken) {
    headers.set('Authorization', `Bearer ${accessToken}`);
  }
  if (forwardedFor) {
    headers.set('X-Forwarded-For', forwardedFor);
  }

  return fetch(new URL(path, serverEnv().backendUrl), {
    method,
    headers,
    body,
    cache: 'no-store',
    signal: AbortSignal.timeout(BACKEND_TIMEOUT_MS),
  });
}

export async function refreshSession(
  refreshToken: string,
  forwardedFor: string | null,
): Promise<AuthTokens | null> {
  const response = await backendFetch('/api/auth/refresh', {
    method: 'POST',
    body: JSON.stringify({ refreshToken }),
    forwardedFor,
  });
  return response.ok ? ((await response.json()) as AuthTokens) : null;
}
