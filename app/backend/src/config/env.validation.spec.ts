import { validateEnv } from './env.validation';

const validEnv = {
  DB_HOST: 'localhost',
  DB_NAME: 'tasksdb',
  DB_USER: 'postgres',
  DB_PASSWORD: 'postgres-password',
  JWT_SECRET: 'a'.repeat(32),
  GOOGLE_CLIENT_ID: 'client-id.apps.googleusercontent.com',
};

describe('validateEnv', () => {
  it('accepts a complete environment and applies defaults', () => {
    const env = validateEnv(validEnv);

    expect(env.DB_PORT).toBe(5432);
    expect(env.PORT).toBe(3001);
  });

  it('converts numeric strings from the environment', () => {
    const env = validateEnv({ ...validEnv, DB_PORT: '6543', PORT: '8080' });

    expect(env.DB_PORT).toBe(6543);
    expect(env.PORT).toBe(8080);
  });

  it('rejects a JWT secret shorter than 32 characters without echoing it', () => {
    const secret = 'too-short-secret';

    expect(() => validateEnv({ ...validEnv, JWT_SECRET: secret })).toThrow(
      /JWT_SECRET/,
    );
    expect(() => validateEnv({ ...validEnv, JWT_SECRET: secret })).not.toThrow(
      new RegExp(secret),
    );
  });

  it('keeps rate-limit counts in memory unless a Redis host is set', () => {
    const env = validateEnv(validEnv);

    expect(env.REDIS_HOST).toBeUndefined();
    expect(env.REDIS_PORT).toBe(6379);
  });

  it('refuses a Redis host without a password', () => {
    expect(() => validateEnv({ ...validEnv, REDIS_HOST: 'redis' })).toThrow(
      /REDIS_PASSWORD/,
    );
    expect(
      validateEnv({ ...validEnv, REDIS_HOST: 'redis', REDIS_PASSWORD: 'p' })
        .REDIS_HOST,
    ).toBe('redis');
  });

  it('accepts a missing Google client id, which switches Google sign-in off', () => {
    const { GOOGLE_CLIENT_ID: _omitted, ...withoutClientId } = validEnv;

    expect(validateEnv(withoutClientId).GOOGLE_CLIENT_ID).toBeUndefined();
  });
});
