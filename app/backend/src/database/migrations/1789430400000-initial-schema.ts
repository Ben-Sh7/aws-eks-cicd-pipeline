import type { MigrationInterface, QueryRunner } from 'typeorm';

export class InitialSchema1789430400000 implements MigrationInterface {
  name = 'InitialSchema1789430400000';

  async up(queryRunner: QueryRunner): Promise<void> {
    // v1 of the app created an unowned tasks(id serial, title) table on startup.
    // Its rows are kept rather than dropped; they have no user to belong to in
    // this schema. Constraint names below are explicit so they cannot collide
    // with the legacy table's tasks_pkey.
    await queryRunner.query(
      `ALTER TABLE IF EXISTS tasks RENAME TO legacy_tasks`,
    );

    await queryRunner.query(`
      CREATE TABLE users (
        id          uuid         NOT NULL DEFAULT gen_random_uuid(),
        google_sub  varchar(255) NOT NULL,
        email       varchar(320) NOT NULL,
        name        varchar(255),
        avatar_url  text,
        created_at  timestamptz  NOT NULL DEFAULT now(),
        updated_at  timestamptz  NOT NULL DEFAULT now(),
        CONSTRAINT pk_users PRIMARY KEY (id),
        CONSTRAINT uq_users_google_sub UNIQUE (google_sub)
      )
    `);

    await queryRunner.query(`
      CREATE TABLE refresh_tokens (
        id          uuid        NOT NULL DEFAULT gen_random_uuid(),
        user_id     uuid        NOT NULL,
        token_hash  char(64)    NOT NULL,
        expires_at  timestamptz NOT NULL,
        rotated_at  timestamptz,
        revoked_at  timestamptz,
        created_at  timestamptz NOT NULL DEFAULT now(),
        CONSTRAINT pk_refresh_tokens PRIMARY KEY (id),
        CONSTRAINT uq_refresh_tokens_token_hash UNIQUE (token_hash),
        CONSTRAINT fk_refresh_tokens_user FOREIGN KEY (user_id)
          REFERENCES users (id) ON DELETE CASCADE
      )
    `);
    await queryRunner.query(
      `CREATE INDEX idx_refresh_tokens_user ON refresh_tokens (user_id)`,
    );

    await queryRunner.query(
      `CREATE TYPE task_status AS ENUM ('todo', 'in_progress', 'done')`,
    );
    await queryRunner.query(
      `CREATE TYPE task_priority AS ENUM ('low', 'medium', 'high')`,
    );
    await queryRunner.query(`
      CREATE TABLE tasks (
        id           uuid          NOT NULL DEFAULT gen_random_uuid(),
        user_id      uuid          NOT NULL,
        title        varchar(200)  NOT NULL,
        description  text,
        status       task_status   NOT NULL DEFAULT 'todo',
        priority     task_priority NOT NULL DEFAULT 'medium',
        due_date     date,
        created_at   timestamptz   NOT NULL DEFAULT now(),
        updated_at   timestamptz   NOT NULL DEFAULT now(),
        CONSTRAINT pk_tasks PRIMARY KEY (id),
        CONSTRAINT fk_tasks_user FOREIGN KEY (user_id)
          REFERENCES users (id) ON DELETE CASCADE
      )
    `);
    await queryRunner.query(
      `CREATE INDEX idx_tasks_user_created ON tasks (user_id, created_at DESC)`,
    );
  }

  async down(queryRunner: QueryRunner): Promise<void> {
    await queryRunner.query(`DROP TABLE tasks`);
    await queryRunner.query(`DROP TYPE task_priority`);
    await queryRunner.query(`DROP TYPE task_status`);
    await queryRunner.query(`DROP TABLE refresh_tokens`);
    await queryRunner.query(`DROP TABLE users`);
    await queryRunner.query(
      `ALTER TABLE IF EXISTS legacy_tasks RENAME TO tasks`,
    );
  }
}
