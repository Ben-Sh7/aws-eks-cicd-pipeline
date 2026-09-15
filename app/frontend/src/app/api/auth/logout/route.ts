import { type NextRequest, NextResponse } from 'next/server';
import { backendFetch } from '@/lib/server/backend';
import { jsonError } from '@/lib/server/bff';
import { isSameOrigin } from '@/lib/server/same-origin';
import { clearSessionCookies, REFRESH_COOKIE } from '@/lib/server/session-cookies';

export async function POST(request: NextRequest) {
  if (!isSameOrigin(request)) {
    return jsonError(403, 'Cross-origin request rejected');
  }

  const refreshToken = request.cookies.get(REFRESH_COOKIE)?.value;
  if (refreshToken) {
    try {
      await backendFetch('/api/auth/logout', {
        method: 'POST',
        body: JSON.stringify({ refreshToken }),
        forwardedFor: request.headers.get('x-forwarded-for'),
      });
    } catch (error) {
      // The cookies are cleared regardless; the token then simply expires.
      console.error('Backend logout failed', error);
    }
  }

  const response = new NextResponse(null, { status: 204 });
  clearSessionCookies(response.cookies);
  return response;
}
