import { connection, NextResponse } from 'next/server';
import * as client from 'openid-client';
import { serverEnv } from '@/lib/server/env';
import {
  callbackUrl,
  encodeOAuthTransaction,
  googleOidc,
} from '@/lib/server/oidc';
import {
  cookieOptions,
  OAUTH_CALLBACK_PATH,
  OAUTH_COOKIE,
} from '@/lib/server/session-cookies';

// Only has to survive the round trip to Google and back.
const OAUTH_TRANSACTION_TTL_SECONDS = 10 * 60;

// Starts the Authorization Code flow with PKCE. state guards the callback
// against CSRF, nonce binds the ID token to this login, and the PKCE verifier
// makes an intercepted authorization code useless on its own.
export async function GET() {
  await connection();

  if (!serverEnv().google) {
    return NextResponse.redirect(
      new URL('/login?error=google_disabled', serverEnv().appUrl),
    );
  }

  let config: client.Configuration;
  try {
    config = await googleOidc();
  } catch (error) {
    console.error('Google OpenID discovery failed', error);
    return NextResponse.redirect(
      new URL('/login?error=google_unavailable', serverEnv().appUrl),
    );
  }

  const codeVerifier = client.randomPKCECodeVerifier();
  const state = client.randomState();
  const nonce = client.randomNonce();

  const authorizationUrl = client.buildAuthorizationUrl(config, {
    redirect_uri: callbackUrl(),
    scope: 'openid email profile',
    code_challenge: await client.calculatePKCECodeChallenge(codeVerifier),
    code_challenge_method: 'S256',
    state,
    nonce,
    prompt: 'select_account',
  });

  const response = NextResponse.redirect(authorizationUrl);
  response.cookies.set(
    OAUTH_COOKIE,
    encodeOAuthTransaction({ codeVerifier, state, nonce }),
    {
      ...cookieOptions(OAUTH_CALLBACK_PATH),
      maxAge: OAUTH_TRANSACTION_TTL_SECONDS,
    },
  );
  return response;
}
