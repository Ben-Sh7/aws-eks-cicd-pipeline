import * as client from 'openid-client';
import { serverEnv } from './env';
import { OAUTH_CALLBACK_PATH } from './session-cookies';

const GOOGLE_ISSUER = new URL('https://accounts.google.com');

let configuration: Promise<client.Configuration> | undefined;

// Google's discovery document (endpoints, signing keys) is fetched once per
// process and reused. A failed fetch is not cached, so the next sign-in retries.
export function googleOidc(): Promise<client.Configuration> {
  if (!configuration) {
    const { google } = serverEnv();
    if (!google) {
      return Promise.reject(new Error('Google sign-in is not enabled'));
    }
    configuration = client
      .discovery(GOOGLE_ISSUER, google.clientId, google.clientSecret)
      .catch((error: unknown) => {
        configuration = undefined;
        throw error;
      });
  }
  return configuration;
}

// Must match a redirect URI registered on the Google OAuth client exactly.
export function callbackUrl(): string {
  return `${serverEnv().appUrl}${OAUTH_CALLBACK_PATH}`;
}

// The per-login secrets that must survive the round trip to Google. They live
// in a short-lived httpOnly cookie, never in the URL.
export interface OAuthTransaction {
  codeVerifier: string;
  state: string;
  nonce: string;
}

export function encodeOAuthTransaction(transaction: OAuthTransaction): string {
  return Buffer.from(JSON.stringify(transaction)).toString('base64url');
}

export function decodeOAuthTransaction(
  value: string | undefined,
): OAuthTransaction | null {
  if (!value) {
    return null;
  }
  try {
    const parsed = JSON.parse(
      Buffer.from(value, 'base64url').toString('utf8'),
    ) as Partial<OAuthTransaction>;
    const { codeVerifier, state, nonce } = parsed;
    return typeof codeVerifier === 'string' &&
      typeof state === 'string' &&
      typeof nonce === 'string'
      ? { codeVerifier, state, nonce }
      : null;
  } catch {
    return null;
  }
}
