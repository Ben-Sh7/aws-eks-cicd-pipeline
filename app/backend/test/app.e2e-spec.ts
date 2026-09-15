import { UnauthorizedException } from '@nestjs/common';
import { JwtService } from '@nestjs/jwt';
import type { NestExpressApplication } from '@nestjs/platform-express';
import { Test } from '@nestjs/testing';
import request from 'supertest';
import type { App } from 'supertest/types';
import { DataSource } from 'typeorm';
import { AppModule } from '../src/app.module';
import { configureApp } from '../src/app.setup';
import {
  JWT_AUDIENCE,
  JWT_ISSUER,
  REFRESH_REUSE_GRACE_MS,
} from '../src/auth/auth.constants';
import type { AuthTokens } from '../src/auth/auth.service';
import {
  type GoogleIdentity,
  GoogleTokenVerifier,
} from '../src/auth/google-token-verifier.service';
import type { TaskResponse } from '../src/tasks/task.response';

// Google is replaced by a fake that maps opaque test tokens to identities.
// Everything else - guards, validation, migrations, Postgres - is real.
const identities: Record<string, GoogleIdentity> = {
  'google-token-alice': {
    sub: 'google-sub-alice',
    email: 'alice@example.com',
    name: 'Alice',
    picture: null,
  },
  'google-token-bob': {
    sub: 'google-sub-bob',
    email: 'bob@example.com',
    name: 'Bob',
    picture: null,
  },
};

const fakeGoogleVerifier = {
  verify: (idToken: string): Promise<GoogleIdentity> => {
    const identity = identities[idToken];
    return identity
      ? Promise.resolve(identity)
      : Promise.reject(new UnauthorizedException());
  },
};

async function createApp(
  reuseGraceMs: number,
): Promise<NestExpressApplication> {
  const moduleRef = await Test.createTestingModule({ imports: [AppModule] })
    .overrideProvider(GoogleTokenVerifier)
    .useValue(fakeGoogleVerifier)
    .overrideProvider(REFRESH_REUSE_GRACE_MS)
    .useValue(reuseGraceMs)
    .compile();

  const app = moduleRef.createNestApplication<NestExpressApplication>();
  configureApp(app);
  await app.init();
  return app;
}

async function loginOn(server: App, idToken: string): Promise<AuthTokens> {
  const response = await request(server)
    .post('/api/auth/google')
    .send({ idToken })
    .expect(200);
  return response.body as AuthTokens;
}

describe('Task Manager API (e2e)', () => {
  let app: NestExpressApplication;
  let server: App;

  const login = (idToken: string) => loginOn(server, idToken);

  const bearer = (tokens: AuthTokens) => `Bearer ${tokens.accessToken}`;

  beforeAll(async () => {
    // No grace window, so reuse detection is observable immediately.
    app = await createApp(0);
    server = app.getHttpServer();

    await app
      .get(DataSource)
      .query('TRUNCATE users, refresh_tokens, tasks CASCADE');
  });

  afterAll(async () => {
    await app?.close();
  });

  describe('health', () => {
    it('reports the database as up, without authentication', async () => {
      const response = await request(server).get('/health').expect(200);

      expect(response.body).toMatchObject({
        status: 'ok',
        info: { database: { status: 'up' } },
      });
    });
  });

  describe('authentication', () => {
    it('rejects API calls without an access token', async () => {
      await request(server).get('/api/tasks').expect(401);
    });

    it('rejects an access token signed with a different secret', async () => {
      const forged = await new JwtService({ secret: 'f'.repeat(40) }).signAsync(
        { sub: 'anyone' },
        { issuer: JWT_ISSUER, audience: JWT_AUDIENCE },
      );

      await request(server)
        .get('/api/tasks')
        .set('Authorization', `Bearer ${forged}`)
        .expect(401);
    });

    it('rejects a Google token the verifier does not accept', async () => {
      await request(server)
        .post('/api/auth/google')
        .send({ idToken: 'not-a-real-token' })
        .expect(401);
    });

    it('rejects unexpected fields in the login body', async () => {
      await request(server)
        .post('/api/auth/google')
        .send({ idToken: 'google-token-alice', isAdmin: true })
        .expect(400);
    });

    it('logs in with Google, returns tokens, and creates the user once', async () => {
      const first = await login('google-token-alice');
      const second = await login('google-token-alice');

      expect(first).toMatchObject({
        accessTokenExpiresIn: 900,
        refreshTokenExpiresIn: 604800,
      });
      const me = await request(server)
        .get('/api/auth/me')
        .set('Authorization', bearer(second))
        .expect(200);
      expect(me.body).toMatchObject({
        email: 'alice@example.com',
        name: 'Alice',
      });

      const users = await app
        .get(DataSource)
        .query<{ count: string }[]>(
          `SELECT count(*) FROM users WHERE google_sub = 'google-sub-alice'`,
        );
      expect(users[0].count).toBe('1');
    });
  });

  describe('refresh tokens', () => {
    it('rotates: the new pair works and the old refresh token is spent', async () => {
      const original = await login('google-token-alice');

      const rotated = await request(server)
        .post('/api/auth/refresh')
        .send({ refreshToken: original.refreshToken })
        .expect(200);
      const next = rotated.body as AuthTokens;

      expect(next.refreshToken).not.toBe(original.refreshToken);
      await request(server)
        .get('/api/tasks')
        .set('Authorization', bearer(next))
        .expect(200);
    });

    it('treats reuse of a rotated token as theft and revokes every session', async () => {
      const original = await login('google-token-bob');
      const rotated = await request(server)
        .post('/api/auth/refresh')
        .send({ refreshToken: original.refreshToken })
        .expect(200);
      const legitimate = rotated.body as AuthTokens;

      // The attacker replays the old token...
      await request(server)
        .post('/api/auth/refresh')
        .send({ refreshToken: original.refreshToken })
        .expect(401);

      // ...and the legitimate holder's newer token is revoked with it.
      await request(server)
        .post('/api/auth/refresh')
        .send({ refreshToken: legitimate.refreshToken })
        .expect(401);
    });

    it('logout revokes the refresh token', async () => {
      const tokens = await login('google-token-alice');

      await request(server)
        .post('/api/auth/logout')
        .send({ refreshToken: tokens.refreshToken })
        .expect(204);
      await request(server)
        .post('/api/auth/refresh')
        .send({ refreshToken: tokens.refreshToken })
        .expect(401);
    });

    it('rejects an unknown refresh token', async () => {
      await request(server)
        .post('/api/auth/refresh')
        .send({ refreshToken: 'never-issued' })
        .expect(401);
    });
  });

  describe('tasks', () => {
    let alice: AuthTokens;
    let bob: AuthTokens;

    beforeAll(async () => {
      alice = await login('google-token-alice');
      bob = await login('google-token-bob');
    });

    it('creates a task with defaults', async () => {
      const response = await request(server)
        .post('/api/tasks')
        .set('Authorization', bearer(alice))
        .send({ title: '  Write the e2e tests  ' })
        .expect(201);

      expect(response.body).toMatchObject({
        title: 'Write the e2e tests',
        description: null,
        status: 'todo',
        priority: 'medium',
        dueDate: null,
      });
      expect(response.body).not.toHaveProperty('userId');
    });

    it.each([
      ['an empty title', { title: '   ' }],
      ['an unknown status', { title: 'Task', status: 'blocked' }],
      ['a malformed due date', { title: 'Task', dueDate: '15/09/2026' }],
      ['an impossible due date', { title: 'Task', dueDate: '2026-02-30' }],
      ['an attempt to set the owner', { title: 'Task', userId: 'someone' }],
    ])('rejects %s', async (_case, body) => {
      await request(server)
        .post('/api/tasks')
        .set('Authorization', bearer(alice))
        .send(body)
        .expect(400);
    });

    it('supports the full lifecycle and filtering', async () => {
      const created = await request(server)
        .post('/api/tasks')
        .set('Authorization', bearer(alice))
        .send({
          title: 'Ship v2',
          description: 'Next.js + NestJS',
          priority: 'high',
          dueDate: '2026-10-01',
        })
        .expect(201);
      const task = created.body as TaskResponse;

      const updated = await request(server)
        .patch(`/api/tasks/${task.id}`)
        .set('Authorization', bearer(alice))
        .send({ status: 'done', description: null })
        .expect(200);
      expect(updated.body).toMatchObject({
        title: 'Ship v2',
        status: 'done',
        description: null,
        priority: 'high',
        dueDate: '2026-10-01',
      });

      const done = await request(server)
        .get('/api/tasks?status=done')
        .set('Authorization', bearer(alice))
        .expect(200);
      expect((done.body as TaskResponse[]).map((t) => t.id)).toEqual([task.id]);

      await request(server)
        .patch(`/api/tasks/${task.id}`)
        .set('Authorization', bearer(alice))
        .send({ title: null })
        .expect(400);

      await request(server)
        .delete(`/api/tasks/${task.id}`)
        .set('Authorization', bearer(alice))
        .expect(204);
      await request(server)
        .get(`/api/tasks/${task.id}`)
        .set('Authorization', bearer(alice))
        .expect(404);
    });

    it("hides one user's tasks from another", async () => {
      const created = await request(server)
        .post('/api/tasks')
        .set('Authorization', bearer(alice))
        .send({ title: "Alice's private task" })
        .expect(201);
      const task = created.body as TaskResponse;

      const bobsList = await request(server)
        .get('/api/tasks')
        .set('Authorization', bearer(bob))
        .expect(200);
      expect((bobsList.body as TaskResponse[]).map((t) => t.id)).not.toContain(
        task.id,
      );

      await request(server)
        .get(`/api/tasks/${task.id}`)
        .set('Authorization', bearer(bob))
        .expect(404);
      await request(server)
        .patch(`/api/tasks/${task.id}`)
        .set('Authorization', bearer(bob))
        .send({ title: 'Hijacked' })
        .expect(404);
      await request(server)
        .delete(`/api/tasks/${task.id}`)
        .set('Authorization', bearer(bob))
        .expect(404);

      const stillThere = await request(server)
        .get(`/api/tasks/${task.id}`)
        .set('Authorization', bearer(alice))
        .expect(200);
      expect(stillThere.body).toMatchObject({ title: "Alice's private task" });
    });

    it('rejects a task id that is not a UUID', async () => {
      await request(server)
        .get('/api/tasks/123')
        .set('Authorization', bearer(alice))
        .expect(400);
    });
  });
});

describe('Refresh token grace window (e2e)', () => {
  let app: NestExpressApplication;
  let server: App;

  const refresh = (refreshToken: string) =>
    request(server).post('/api/auth/refresh').send({ refreshToken });

  beforeAll(async () => {
    app = await createApp(60_000);
    server = app.getHttpServer();
  });

  afterAll(async () => {
    await app?.close();
  });

  it('accepts a just-rotated token again, as parallel requests race to refresh', async () => {
    const tokens = await loginOn(server, 'google-token-alice');

    await refresh(tokens.refreshToken).expect(200);
    await refresh(tokens.refreshToken).expect(200);
  });

  it('gives a logged-out token no grace', async () => {
    const tokens = await loginOn(server, 'google-token-alice');

    await request(server)
      .post('/api/auth/logout')
      .send({ refreshToken: tokens.refreshToken })
      .expect(204);
    await refresh(tokens.refreshToken).expect(401);
  });
});

describe('Username and password accounts (e2e)', () => {
  const PASSWORD = 'correct horse battery staple';
  let app: NestExpressApplication;
  let server: App;

  const register = (body: object) =>
    request(server).post('/api/auth/register').send(body);
  const passwordLogin = (body: object) =>
    request(server).post('/api/auth/login').send(body);

  beforeAll(async () => {
    app = await createApp(0);
    server = app.getHttpServer();
  });

  afterAll(async () => {
    await app?.close();
  });

  it('registers, signs in, and stores only an argon2id hash', async () => {
    const response = await register({
      username: '  Carol.Test ',
      password: PASSWORD,
      name: 'Carol',
    }).expect(201);
    const tokens = response.body as AuthTokens;

    const me = await request(server)
      .get('/api/auth/me')
      .set('Authorization', `Bearer ${tokens.accessToken}`)
      .expect(200);
    expect(me.body).toEqual({
      id: expect.any(String) as string,
      username: 'carol.test',
      email: null,
      name: 'Carol',
      avatarUrl: null,
    });

    const rows = await app
      .get(DataSource)
      .query<{ password_hash: string }[]>(
        `SELECT password_hash FROM users WHERE username = 'carol.test'`,
      );
    expect(rows[0].password_hash).toMatch(/^\$argon2id\$/);
    expect(rows[0].password_hash).not.toContain(PASSWORD);
  });

  it('treats usernames case-insensitively when checking they are free', async () => {
    const response = await register({
      username: 'CAROL.test',
      password: PASSWORD,
    }).expect(409);

    expect(response.body).toMatchObject({
      message: 'Username is already taken',
    });
  });

  it.each([
    ['a password shorter than 12 characters', { password: 'short-pass1' }],
    ['a username with spaces', { username: 'carol smith' }],
    ['a username shorter than 3 characters', { username: 'ab' }],
    ['an attempt to set other columns', { googleSub: 'google-sub-alice' }],
  ])('rejects registering with %s', async (_case, override) => {
    await register({
      username: 'dave',
      password: PASSWORD,
      ...override,
    }).expect(400);
  });

  it('logs in with the right password, whatever the username case', async () => {
    const response = await passwordLogin({
      username: 'Carol.TEST',
      password: PASSWORD,
    }).expect(200);

    await request(server)
      .get('/api/tasks')
      .set(
        'Authorization',
        `Bearer ${(response.body as AuthTokens).accessToken}`,
      )
      .expect(200);
  });

  it('answers a wrong password and an unknown user identically', async () => {
    const wrongPassword = await passwordLogin({
      username: 'carol.test',
      password: 'not the right password',
    }).expect(401);
    const unknownUser = await passwordLogin({
      username: 'nobody-here',
      password: PASSWORD,
    }).expect(401);

    expect(wrongPassword.body).toEqual(unknownUser.body);
    expect(wrongPassword.body).toMatchObject({
      message: 'Invalid username or password',
    });
  });

  it('cannot log into a Google account with a username', async () => {
    await passwordLogin({
      username: 'google-sub-alice',
      password: PASSWORD,
    }).expect(401);
  });
});
