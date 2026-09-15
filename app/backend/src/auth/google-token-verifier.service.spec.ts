import { NotFoundException, UnauthorizedException } from '@nestjs/common';
import type { ConfigService } from '@nestjs/config';
import {
  type LoginTicket,
  OAuth2Client,
  type TokenPayload,
} from 'google-auth-library';
import type { Env } from '../config/env.validation';
import { GoogleTokenVerifier } from './google-token-verifier.service';

const CLIENT_ID = 'client-id.apps.googleusercontent.com';

const validPayload: TokenPayload = {
  iss: 'https://accounts.google.com',
  aud: CLIENT_ID,
  sub: '1234567890',
  email: 'user@example.com',
  email_verified: true,
  name: 'Test User',
  picture: 'https://example.com/avatar.png',
  iat: 0,
  exp: 0,
};

function ticketFor(payload: TokenPayload | undefined): LoginTicket {
  return { getPayload: () => payload } as unknown as LoginTicket;
}

function verifierWithClientId(clientId: string | undefined) {
  return new GoogleTokenVerifier({
    get: () => clientId,
  } as unknown as ConfigService<Env, true>);
}

describe('GoogleTokenVerifier', () => {
  let verifier: GoogleTokenVerifier;
  let verifyIdToken: jest.SpyInstance;

  beforeEach(() => {
    verifier = verifierWithClientId(CLIENT_ID);
    verifyIdToken = jest.spyOn(OAuth2Client.prototype, 'verifyIdToken');
  });

  afterEach(() => {
    jest.restoreAllMocks();
  });

  it('returns the identity of a valid token and checks it against our client id', async () => {
    verifyIdToken.mockResolvedValue(ticketFor(validPayload));

    await expect(verifier.verify('id-token')).resolves.toEqual({
      sub: '1234567890',
      email: 'user@example.com',
      name: 'Test User',
      picture: 'https://example.com/avatar.png',
    });
    expect(verifyIdToken).toHaveBeenCalledWith({
      idToken: 'id-token',
      audience: CLIENT_ID,
    });
  });

  it('rejects a token the library fails to verify (signature, expiry, audience)', async () => {
    verifyIdToken.mockRejectedValue(new Error('Wrong recipient'));

    await expect(verifier.verify('id-token')).rejects.toBeInstanceOf(
      UnauthorizedException,
    );
  });

  it.each<[string, Partial<TokenPayload>]>([
    ['an unverified email', { email_verified: false }],
    ['a missing email', { email: undefined }],
    ['a foreign issuer', { iss: 'https://evil.example.com' }],
  ])('rejects a token with %s', async (_case, override) => {
    verifyIdToken.mockResolvedValue(
      ticketFor({ ...validPayload, ...override }),
    );

    await expect(verifier.verify('id-token')).rejects.toBeInstanceOf(
      UnauthorizedException,
    );
  });

  it('rejects a ticket without a payload', async () => {
    verifyIdToken.mockResolvedValue(ticketFor(undefined));

    await expect(verifier.verify('id-token')).rejects.toBeInstanceOf(
      UnauthorizedException,
    );
  });

  it.each([
    ['no client id', undefined],
    ['an empty client id', ''],
  ])(
    'refuses every token without asking Google when configured with %s',
    async (_case, clientId) => {
      await expect(
        verifierWithClientId(clientId).verify('id-token'),
      ).rejects.toBeInstanceOf(NotFoundException);
      expect(verifyIdToken).not.toHaveBeenCalled();
    },
  );
});
