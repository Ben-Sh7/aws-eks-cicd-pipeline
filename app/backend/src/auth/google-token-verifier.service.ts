import {
  Injectable,
  NotFoundException,
  UnauthorizedException,
} from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { OAuth2Client, type TokenPayload } from 'google-auth-library';
import type { Env } from '../config/env.validation';

export interface GoogleIdentity {
  sub: string;
  email: string;
  name: string | null;
  picture: string | null;
}

const GOOGLE_ISSUERS = new Set([
  'accounts.google.com',
  'https://accounts.google.com',
]);

// Verifies Google ID tokens locally against Google's published signing keys,
// which the library fetches and caches. The frontend already validated this
// token during the code exchange; the backend checks it again because it must
// not trust its caller.
//
// Google sign-in is optional. Without GOOGLE_CLIENT_ID every token is refused.
@Injectable()
export class GoogleTokenVerifier {
  private readonly client = new OAuth2Client();
  private readonly clientId: string | undefined;

  constructor(config: ConfigService<Env, true>) {
    // An empty value, such as an unset compose variable, counts as unset.
    this.clientId =
      config.get('GOOGLE_CLIENT_ID', { infer: true }) || undefined;
  }

  async verify(idToken: string): Promise<GoogleIdentity> {
    // Without a client id there is no audience to check the token against,
    // and verifyIdToken would accept a token issued to any Google client.
    const audience = this.clientId;
    if (!audience) {
      throw new NotFoundException('Google sign-in is not enabled');
    }

    let payload: TokenPayload | undefined;
    try {
      // Checks the signature, expiry, and that `aud` is our client id.
      const ticket = await this.client.verifyIdToken({ idToken, audience });
      payload = ticket.getPayload();
    } catch {
      throw new UnauthorizedException('Invalid Google ID token');
    }

    if (
      !payload ||
      !GOOGLE_ISSUERS.has(payload.iss) ||
      !payload.sub ||
      !payload.email ||
      payload.email_verified !== true
    ) {
      throw new UnauthorizedException('Invalid Google ID token');
    }

    return {
      sub: payload.sub,
      email: payload.email,
      name: payload.name ?? null,
      picture: payload.picture ?? null,
    };
  }
}
