import { type NextRequest, NextResponse } from 'next/server';
import * as client from 'openid-client';
import { type AuthTokens, backendFetch } from '@/lib/server/backend';
import { serverEnv } from '@/lib/server/env';
import {
  callbackUrl,
  decodeOAuthTransaction,
  googleOidc,
} from '@/lib/server/oidc';
import {
  clearOAuthCookie,
  OAUTH_COOKIE,
  setSessionCookies,
} from '@/lib/server/session-cookies';

// Google redirects here after sign-in. The code is exchanged for an ID token
// server-side (with the client secret), the backend verifies that token and
// issues this app's own JWT pair, and the pair is stored in httpOnly cookies.
// Google's tokens are discarded; neither they nor ours reach page JavaScript.
export async function GET(request: NextRequest) {
  const { appUrl } = serverEnv();

  const fail = (reason: string) => {
    const response = NextResponse.redirect(
      new URL(`/login?error=${reason}`, appUrl),
    );
    clearOAuthCookie(response.cookies);
    return response;
  };

  const transaction = decodeOAuthTransaction(
    request.cookies.get(OAUTH_COOKIE)?.value,
  );
  if (!transaction) {
    return fail('session_expired');
  }

  let idToken: string;
  try {
    // Rebuilt from APP_URL: behind the ingress request.url carries the pod's
    // internal address, and the redirect_uri derived from this URL must match
    // the one sent in the authorization request exactly.
    const currentUrl = new URL(`${callbackUrl()}${request.nextUrl.search}`);
    // Validates state, the ID token's signature/issuer/audience/expiry, and
    // that its nonce matches this login.
    const tokens = await client.authorizationCodeGrant(
      await googleOidc(),
      currentUrl,
      {
        pkceCodeVerifier: transaction.codeVerifier,
        expectedState: transaction.state,
        expectedNonce: transaction.nonce,
      },
    );
    if (!tokens.id_token) {
      throw new Error('Google returned no ID token');
    }
    idToken = tokens.id_token;
  } catch (error) {
    console.error('Google code exchange failed', error);
    return fail('google_sign_in_failed');
  }

  let backendResponse: Response;
  try {
    backendResponse = await backendFetch('/api/auth/google', {
      method: 'POST',
      body: JSON.stringify({ idToken }),
      forwardedFor: request.headers.get('x-forwarded-for'),
    });
  } catch (error) {
    console.error('Backend sign-in request failed', error);
    return fail('server_unavailable');
  }
  if (!backendResponse.ok) {
    return fail('sign_in_rejected');
  }

  const response = NextResponse.redirect(new URL('/', appUrl));
  setSessionCookies(response.cookies, (await backendResponse.json()) as AuthTokens);
  clearOAuthCookie(response.cookies);
  return response;
}
