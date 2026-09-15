import type { MigrationInterface, QueryRunner } from 'typeorm';

export class AddPasswordAuth1789479000000 implements MigrationInterface {
  name = 'AddPasswordAuth1789479000000';

  // Accounts can now be created with a username and password as well as with
  // Google. Both identity columns become optional, and a check constraint
  // guarantees that every account still has at least one way to sign in.
  async up(queryRunner: QueryRunner): Promise<void> {
    await queryRunner.query(
      `ALTER TABLE users ALTER COLUMN google_sub DROP NOT NULL`,
    );
    await queryRunner.query(
      `ALTER TABLE users ALTER COLUMN email DROP NOT NULL`,
    );
    await queryRunner.query(
      `ALTER TABLE users ADD COLUMN username varchar(32)`,
    );
    await queryRunner.query(`ALTER TABLE users ADD COLUMN password_hash text`);
    await queryRunner.query(
      `ALTER TABLE users ADD CONSTRAINT uq_users_username UNIQUE (username)`,
    );
    // Usernames are case-insensitive; storing them lowercase lets a plain
    // unique constraint enforce that.
    await queryRunner.query(
      `ALTER TABLE users ADD CONSTRAINT ck_users_username_lowercase CHECK (username = lower(username))`,
    );
    await queryRunner.query(`
      ALTER TABLE users ADD CONSTRAINT ck_users_has_credential CHECK (
        google_sub IS NOT NULL
        OR (username IS NOT NULL AND password_hash IS NOT NULL)
      )
    `);
  }

  async down(queryRunner: QueryRunner): Promise<void> {
    // Password-only accounts cannot exist in the previous schema.
    await queryRunner.query(`DELETE FROM users WHERE google_sub IS NULL`);
    await queryRunner.query(
      `ALTER TABLE users DROP CONSTRAINT ck_users_has_credential`,
    );
    await queryRunner.query(
      `ALTER TABLE users DROP CONSTRAINT ck_users_username_lowercase`,
    );
    await queryRunner.query(
      `ALTER TABLE users DROP CONSTRAINT uq_users_username`,
    );
    await queryRunner.query(`ALTER TABLE users DROP COLUMN password_hash`);
    await queryRunner.query(`ALTER TABLE users DROP COLUMN username`);
    await queryRunner.query(
      `ALTER TABLE users ALTER COLUMN email SET NOT NULL`,
    );
    await queryRunner.query(
      `ALTER TABLE users ALTER COLUMN google_sub SET NOT NULL`,
    );
  }
}
