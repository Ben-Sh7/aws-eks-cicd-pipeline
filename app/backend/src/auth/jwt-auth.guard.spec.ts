import { type ExecutionContext, UnauthorizedException } from '@nestjs/common';
import type { Reflector } from '@nestjs/core';
import { JwtService } from '@nestjs/jwt';
import { JWT_AUDIENCE, JWT_ISSUER } from './auth.constants';
import type { AuthenticatedRequest } from './current-user.decorator';
import { JwtAuthGuard } from './jwt-auth.guard';

const SECRET = 's'.repeat(40);
const USER_ID = '6f1c1d2e-3b4a-4c5d-8e9f-0a1b2c3d4e5f';

const jwtService = new JwtService({
  secret: SECRET,
  signOptions: {
    algorithm: 'HS256',
    expiresIn: 900,
    issuer: JWT_ISSUER,
    audience: JWT_AUDIENCE,
  },
  verifyOptions: {
    algorithms: ['HS256'],
    issuer: JWT_ISSUER,
    audience: JWT_AUDIENCE,
  },
});

const base64url = (value: object) =>
  Buffer.from(JSON.stringify(value)).toString('base64url');

function contextFor(request: Partial<AuthenticatedRequest>): ExecutionContext {
  return {
    getHandler: () => undefined,
    getClass: () => undefined,
    switchToHttp: () => ({ getRequest: () => request }),
  } as unknown as ExecutionContext;
}

function guardWith(isPublic: boolean): JwtAuthGuard {
  const reflector = {
    getAllAndOverride: () => isPublic,
  } as unknown as Reflector;
  return new JwtAuthGuard(jwtService, reflector);
}

describe('JwtAuthGuard', () => {
  it('lets public routes through without a token', async () => {
    await expect(
      guardWith(true).canActivate(contextFor({ headers: {} })),
    ).resolves.toBe(true);
  });

  it('accepts a valid token and exposes the user id', async () => {
    const token = await jwtService.signAsync({ sub: USER_ID });
    const request: Partial<AuthenticatedRequest> = {
      headers: { authorization: `Bearer ${token}` },
    };

    await expect(
      guardWith(false).canActivate(contextFor(request)),
    ).resolves.toBe(true);
    expect(request.user).toEqual({ id: USER_ID });
  });

  it.each<[string, () => Promise<string | undefined>]>([
    ['no Authorization header', () => Promise.resolve(undefined)],
    [
      'a non-Bearer scheme',
      async () => `Basic ${await jwtService.signAsync({ sub: USER_ID })}`,
    ],
    [
      'a token signed with another secret',
      async () =>
        `Bearer ${await new JwtService({ secret: 'x'.repeat(40) }).signAsync(
          { sub: USER_ID },
          { issuer: JWT_ISSUER, audience: JWT_AUDIENCE },
        )}`,
    ],
    [
      'an unsigned alg:none token',
      () =>
        Promise.resolve(
          `Bearer ${base64url({ alg: 'none', typ: 'JWT' })}.${base64url({
            sub: USER_ID,
            iss: JWT_ISSUER,
            aud: JWT_AUDIENCE,
            exp: Math.floor(Date.now() / 1000) + 600,
          })}.`,
        ),
    ],
    [
      'a token for another audience',
      async () =>
        `Bearer ${await jwtService.signAsync(
          { sub: USER_ID },
          { audience: 'some-other-service' },
        )}`,
    ],
    [
      'an expired token',
      // A service without a default expiresIn, so the payload's own past
      // `exp` is what gets signed.
      async () =>
        `Bearer ${await new JwtService({ secret: SECRET }).signAsync(
          { sub: USER_ID, exp: Math.floor(Date.now() / 1000) - 60 },
          { algorithm: 'HS256', issuer: JWT_ISSUER, audience: JWT_AUDIENCE },
        )}`,
    ],
  ])('rejects %s', async (_case, buildHeader) => {
    const authorization = await buildHeader();
    const request: Partial<AuthenticatedRequest> = {
      headers: authorization ? { authorization } : {},
    };

    await expect(
      guardWith(false).canActivate(contextFor(request)),
    ).rejects.toBeInstanceOf(UnauthorizedException);
    expect(request.user).toBeUndefined();
  });
});
