import { type NextRequest, NextResponse } from 'next/server';
import { type AuthTokens, backendFetch } from './backend';
import { jsonError } from './bff';
import { isSameOrigin } from './same-origin';
import { setSessionCookies } from './session-cookies';

type CredentialsEndpoint = '/api/auth/login' | '/api/auth/register';

// Forwards a username/password sign-in or sign-up to the backend. On success
// the tokens go straight into httpOnly cookies and the browser receives only a
// 204; on failure the backend's status and message pass through unchanged.
export async function exchangeCredentials(
  request: NextRequest,
  endpoint: CredentialsEndpoint,
): Promise<NextResponse> {
  if (!isSameOrigin(request)) {
    return jsonError(403, 'Cross-origin request rejected');
  }

  let upstream: Response;
  try {
    upstream = await backendFetch(endpoint, {
      method: 'POST',
      body: await request.text(),
      forwardedFor: request.headers.get('x-forwarded-for'),
    });
  } catch (error) {
    console.error(`Backend request POST ${endpoint} failed`, error);
    return jsonError(502, 'The server is unavailable. Please try again.');
  }

  if (!upstream.ok) {
    return new NextResponse(await upstream.text(), {
      status: upstream.status,
      headers: {
        'Content-Type': upstream.headers.get('content-type') ?? 'application/json',
      },
    });
  }

  const response = new NextResponse(null, { status: 204 });
  setSessionCookies(response.cookies, (await upstream.json()) as AuthTokens);
  return response;
}
