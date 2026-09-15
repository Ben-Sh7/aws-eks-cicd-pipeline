import {
  Inject,
  Injectable,
  Logger,
  UnauthorizedException,
} from '@nestjs/common';
import { JwtService } from '@nestjs/jwt';
import { createHash, randomBytes } from 'node:crypto';
import { DataSource, EntityManager, IsNull, LessThan } from 'typeorm';
import { UsersService } from '../users/users.service';
import {
  ACCESS_TOKEN_TTL_SECONDS,
  REFRESH_REUSE_GRACE_MS,
  REFRESH_TOKEN_TTL_SECONDS,
} from './auth.constants';
import type { RegisterDto } from './dto/register.dto';
import { GoogleTokenVerifier } from './google-token-verifier.service';
import { PasswordHasher } from './password-hasher.service';
import { RefreshToken } from './refresh-token.entity';

export interface AuthTokens {
  accessToken: string;
  accessTokenExpiresIn: number;
  refreshToken: string;
  refreshTokenExpiresIn: number;
}

type RotationOutcome =
  | { kind: 'rotated'; tokens: AuthTokens }
  | { kind: 'rejected' }
  | { kind: 'reuse-detected'; userId: string };

@Injectable()
export class AuthService {
  private readonly logger = new Logger(AuthService.name);

  constructor(
    private readonly googleVerifier: GoogleTokenVerifier,
    private readonly passwordHasher: PasswordHasher,
    private readonly usersService: UsersService,
    private readonly jwtService: JwtService,
    private readonly dataSource: DataSource,
    @Inject(REFRESH_REUSE_GRACE_MS) private readonly reuseGraceMs: number,
  ) {}

  async loginWithGoogle(idToken: string): Promise<AuthTokens> {
    const identity = await this.googleVerifier.verify(idToken);
    const user = await this.usersService.upsertFromGoogle(identity);
    return this.dataSource.transaction((manager) =>
      this.issueTokens(manager, user.id),
    );
  }

  async register(dto: RegisterDto): Promise<AuthTokens> {
    const passwordHash = await this.passwordHasher.hash(dto.password);
    const user = await this.usersService.createWithPassword(
      dto.username,
      passwordHash,
      dto.name ?? null,
    );
    return this.dataSource.transaction((manager) =>
      this.issueTokens(manager, user.id),
    );
  }

  // One generic error, and the same hashing work, whether the username does
  // not exist or the password is wrong - so neither the message nor the
  // response time reveals which usernames are registered.
  async loginWithPassword(
    username: string,
    password: string,
  ): Promise<AuthTokens> {
    const credentials =
      await this.usersService.findPasswordCredentials(username);
    const valid = await this.passwordHasher.verify(
      credentials?.passwordHash ?? null,
      password,
    );
    if (!credentials || !valid) {
      throw new UnauthorizedException('Invalid username or password');
    }
    return this.dataSource.transaction((manager) =>
      this.issueTokens(manager, credentials.id),
    );
  }

  // Rotation: every refresh token works once and is replaced by a new pair.
  // A rotated token that comes back after the grace window means two parties
  // hold it, so every session of that user is ended. A revoked token (logout,
  // theft detection) gets no grace at all.
  async refresh(rawToken: string): Promise<AuthTokens> {
    // Decided inside the transaction but thrown after it commits: throwing
    // inside would roll back the revocation that reuse detection just wrote.
    const outcome = await this.dataSource.transaction(
      async (manager): Promise<RotationOutcome> => {
        const tokens = manager.getRepository(RefreshToken);
        // The row lock serialises concurrent refreshes of the same token.
        const token = await tokens.findOne({
          where: { tokenHash: hashToken(rawToken) },
          lock: { mode: 'pessimistic_write' },
        });
        if (!token) {
          return { kind: 'rejected' };
        }

        const now = new Date();
        if (token.revokedAt || token.expiresAt <= now) {
          return { kind: 'rejected' };
        }

        if (token.rotatedAt) {
          if (now.getTime() - token.rotatedAt.getTime() > this.reuseGraceMs) {
            await tokens.update(
              { userId: token.userId, revokedAt: IsNull() },
              { revokedAt: now },
            );
            return { kind: 'reuse-detected', userId: token.userId };
          }
        } else {
          token.rotatedAt = now;
          await tokens.save(token);
        }

        return {
          kind: 'rotated',
          tokens: await this.issueTokens(manager, token.userId),
        };
      },
    );

    if (outcome.kind === 'reuse-detected') {
      this.logger.warn(
        `Refresh token reuse detected; revoked all sessions of user ${outcome.userId}`,
      );
    }
    if (outcome.kind !== 'rotated') {
      throw new UnauthorizedException();
    }
    return outcome.tokens;
  }

  async logout(rawToken: string): Promise<void> {
    await this.dataSource
      .getRepository(RefreshToken)
      .update(
        { tokenHash: hashToken(rawToken), revokedAt: IsNull() },
        { revokedAt: new Date() },
      );
  }

  private async issueTokens(
    manager: EntityManager,
    userId: string,
  ): Promise<AuthTokens> {
    const tokens = manager.getRepository(RefreshToken);
    const refreshToken = randomBytes(32).toString('base64url');

    // Pruning expired rows here keeps the table bounded without a cron job.
    // Revoked-but-unexpired rows stay: reuse detection needs them.
    await tokens.delete({ userId, expiresAt: LessThan(new Date()) });
    await tokens.insert({
      userId,
      tokenHash: hashToken(refreshToken),
      expiresAt: new Date(Date.now() + REFRESH_TOKEN_TTL_SECONDS * 1000),
    });

    return {
      accessToken: await this.jwtService.signAsync({ sub: userId }),
      accessTokenExpiresIn: ACCESS_TOKEN_TTL_SECONDS,
      refreshToken,
      refreshTokenExpiresIn: REFRESH_TOKEN_TTL_SECONDS,
    };
  }
}

function hashToken(rawToken: string): string {
  return createHash('sha256').update(rawToken).digest('hex');
}
