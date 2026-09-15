// class-transformer reads the property types that decorators record here.
import 'reflect-metadata';
import { plainToInstance } from 'class-transformer';
import {
  IsInt,
  IsNotEmpty,
  IsOptional,
  IsString,
  Max,
  Min,
  MinLength,
  validateSync,
} from 'class-validator';

// Validated once at startup: a missing or malformed variable stops the process
// with a clear message instead of failing on the first request that needs it.
export class Env {
  @IsString()
  @IsNotEmpty()
  DB_HOST!: string;

  @IsInt()
  @Min(1)
  @Max(65535)
  DB_PORT: number = 5432;

  @IsString()
  @IsNotEmpty()
  DB_NAME!: string;

  @IsString()
  @IsNotEmpty()
  DB_USER!: string;

  @IsString()
  @IsNotEmpty()
  DB_PASSWORD!: string;

  // Path to the RDS CA bundle. Unset or empty means plaintext, which only
  // makes sense against a local Postgres.
  @IsOptional()
  @IsString()
  DB_SSL_CA?: string;

  @IsInt()
  @Min(1)
  @Max(65535)
  PORT: number = 3001;

  // HS256 is only as strong as its key. 32 characters is the floor.
  @IsString()
  @MinLength(32)
  JWT_SECRET!: string;

  // Optional: without it Google sign-in is switched off and only username and
  // password accounts work. Google needs HTTPS and a fixed domain, which the
  // AWS deployment does not have.
  @IsOptional()
  @IsString()
  GOOGLE_CLIENT_ID?: string;
}

export function validateEnv(config: Record<string, unknown>): Env {
  const env = plainToInstance(Env, config, { enableImplicitConversion: true });
  const errors = validateSync(env);
  if (errors.length > 0) {
    // Constraint messages name the variable, never its value.
    const details = errors.flatMap((error) =>
      Object.values(error.constraints ?? {}),
    );
    throw new Error(`Invalid environment: ${details.join('; ')}`);
  }
  return env;
}
