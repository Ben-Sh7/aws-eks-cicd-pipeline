import { type NextRequest, NextResponse } from 'next/server';
import { type AuthTokens, backendFetch, refreshSession } from './backend';
import { isSameOrigin } from './same-origin';
import {
  ACCESS_COOKIE,
  clearSessionCookies,
  REFRESH_COOKIE,
  setSessionCookies,
} from './session-cookies';

type Method = 'GET' | 'POST' | 'PATCH' | 'DELETE';

export function jsonError(status: number, message: string): NextResponse {
  return NextResponse.json({ message }, { status });
}

function signedOut(): NextResponse {
  const response = jsonError(401, 'Not signed in');
  clearSessionCookies(response.cookies);
  return response;
}

// Forwards one browser request to the backend with the user's access token.
// When the access token is missing or rejected it refreshes the session once,
// retries, and hands the rotated tokens back to the browser as cookies.
export async function forwardToBackend(
  request: NextRequest,
  path: string,
  method: Method,
): Promise<NextResponse> {
  if (method !== 'GET' && !isSameOrigin(request)) {
    return jsonError(403, 'Cross-origin request rejected');
  }

  const body = method === 'POST' || method === 'PATCH' ? await request.text() : undefined;
  const forwardedFor = request.headers.get('x-forwarded-for');
  const refreshToken = request.cookies.get(REFRESH_COOKIE)?.value;
  let accessToken = request.cookies.get(ACCESS_COOKIE)?.value;
  let refreshed: AuthTokens | null = null;

  const refresh = async (): Promise<boolean> => {
    if (!refreshToken || refreshed) {
      return false;
    }
    refreshed = await refreshSession(refreshToken, forwardedFor);
    accessToken = refreshed?.accessToken;
    return refreshed !== null;
  };

  try {
    if (!accessToken && !(await refresh())) {
      return signedOut();
    }

    let upstream = await backendFetch(path, { method, body, accessToken, forwardedFor });
    // The access cookie can outlive its token (clock skew, a revoked session);
    // one refresh-and-retry distinguishes that from a real sign-out.
    if (upstream.status === 401) {
      if (!(await refresh())) {
        return signedOut();
      }
      upstream = await backendFetch(path, { method, body, accessToken, forwardedFor });
      if (upstream.status === 401) {
        return signedOut();
      }
    }

    const response = new NextResponse(
      upstream.status === 204 ? null : await upstream.text(),
      {
        status: upstream.status,
        headers: {
          'Content-Type': upstream.headers.get('content-type') ?? 'application/json',
        },
      },
    );
    if (refreshed) {
      setSessionCookies(response.cookies, refreshed);
    }
    return response;
  } catch (error) {
    console.error(`Backend request ${method} ${path} failed`, error);
    return jsonError(502, 'The server is unavailable. Please try again.');
  }
}
