import { Module } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { JwtModule } from '@nestjs/jwt';
import type { Env } from '../config/env.validation';
import { UsersModule } from '../users/users.module';
import {
  ACCESS_TOKEN_TTL_SECONDS,
  DEFAULT_REFRESH_REUSE_GRACE_MS,
  JWT_AUDIENCE,
  JWT_ISSUER,
  REFRESH_REUSE_GRACE_MS,
} from './auth.constants';
import { AuthController } from './auth.controller';
import { AuthService } from './auth.service';
import { GoogleTokenVerifier } from './google-token-verifier.service';
import { PasswordHasher } from './password-hasher.service';

@Module({
  imports: [
    UsersModule,
    JwtModule.registerAsync({
      // Global so the app-wide JwtAuthGuard can verify tokens in every module.
      global: true,
      inject: [ConfigService],
      useFactory: (config: ConfigService<Env, true>) => ({
        secret: config.get('JWT_SECRET', { infer: true }),
        signOptions: {
          algorithm: 'HS256',
          expiresIn: ACCESS_TOKEN_TTL_SECONDS,
          issuer: JWT_ISSUER,
          audience: JWT_AUDIENCE,
        },
        // Pinning the algorithm rejects `alg: none` and algorithm-confusion
        // tokens outright.
        verifyOptions: {
          algorithms: ['HS256'],
          issuer: JWT_ISSUER,
          audience: JWT_AUDIENCE,
        },
      }),
    }),
  ],
  controllers: [AuthController],
  providers: [
    AuthService,
    GoogleTokenVerifier,
    PasswordHasher,
    {
      provide: REFRESH_REUSE_GRACE_MS,
      useValue: DEFAULT_REFRESH_REUSE_GRACE_MS,
    },
  ],
})
export class AuthModule {}
