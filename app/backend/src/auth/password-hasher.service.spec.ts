import { PasswordHasher } from './password-hasher.service';

const PASSWORD = 'correct horse battery staple';

describe('PasswordHasher', () => {
  const hasher = new PasswordHasher();

  beforeAll(() => hasher.onModuleInit());

  it('produces an argon2id hash with the OWASP parameters, never the password itself', async () => {
    const hashed = await hasher.hash(PASSWORD);

    expect(hashed).toMatch(/^\$argon2id\$v=19\$m=19456,p=1,t=2\$/);
    expect(hashed).not.toContain(PASSWORD);
  });

  it('salts every hash, so equal passwords do not produce equal hashes', async () => {
    expect(await hasher.hash(PASSWORD)).not.toBe(await hasher.hash(PASSWORD));
  });

  it('accepts the right password', async () => {
    const hashed = await hasher.hash(PASSWORD);

    await expect(hasher.verify(hashed, PASSWORD)).resolves.toBe(true);
  });

  it('rejects a wrong password', async () => {
    const hashed = await hasher.hash(PASSWORD);

    await expect(hasher.verify(hashed, `${PASSWORD}!`)).resolves.toBe(false);
  });

  it('rejects a missing account without throwing', async () => {
    await expect(hasher.verify(null, PASSWORD)).resolves.toBe(false);
  });

  it('rejects a malformed stored hash without throwing', async () => {
    await expect(hasher.verify('not-a-hash', PASSWORD)).resolves.toBe(false);
  });
});
