import type { NextResponse } from 'next/server';
import type { AuthTokens } from './backend';
import { serverEnv } from './env';

export const ACCESS_COOKIE = 'tm_access';
export const REFRESH_COOKIE = 'tm_refresh';
export const OAUTH_COOKIE = 'tm_oauth';
export const OAUTH_CALLBACK_PATH = '/api/auth/callback';

type ResponseCookies = NextResponse['cookies'];

// The access cookie expires a little before the JWT inside it, so a request is
// never sent with a token that runs out on the way to the backend.
const ACCESS_EXPIRY_MARGIN_SECONDS = 30;

// httpOnly: page JavaScript cannot read the tokens, so XSS cannot steal them.
// SameSite=Lax: not sent on cross-site POST/PATCH/DELETE (CSRF), but still
// sent when Google redirects the browser back to the callback.
// Secure whenever the app is served over HTTPS. Plain-HTTP localhost is the
// one exception, because some browsers drop Secure cookies there.
export function cookieOptions(path = '/') {
  return {
    httpOnly: true,
    secure: serverEnv().appUrl.startsWith('https://'),
    sameSite: 'lax' as const,
    path,
  };
}

export function setSessionCookies(
  cookies: ResponseCookies,
  tokens: AuthTokens,
): void {
  cookies.set(ACCESS_COOKIE, tokens.accessToken, {
    ...cookieOptions(),
    maxAge: Math.max(
      tokens.accessTokenExpiresIn - ACCESS_EXPIRY_MARGIN_SECONDS,
      0,
    ),
  });
  cookies.set(REFRESH_COOKIE, tokens.refreshToken, {
    ...cookieOptions(),
    maxAge: tokens.refreshTokenExpiresIn,
  });
}

export function clearSessionCookies(cookies: ResponseCookies): void {
  for (const name of [ACCESS_COOKIE, REFRESH_COOKIE]) {
    cookies.set(name, '', { ...cookieOptions(), maxAge: 0 });
  }
}

export function clearOAuthCookie(cookies: ResponseCookies): void {
  cookies.set(OAUTH_COOKIE, '', {
    ...cookieOptions(OAUTH_CALLBACK_PATH),
    maxAge: 0,
  });
}
