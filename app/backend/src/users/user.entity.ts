import {
  Column,
  CreateDateColumn,
  Entity,
  PrimaryGeneratedColumn,
  UpdateDateColumn,
} from 'typeorm';

@Entity({ name: 'users' })
export class User {
  @PrimaryGeneratedColumn('uuid')
  id!: string;

  // Google's stable account id. Null for username/password accounts.
  @Column({
    name: 'google_sub',
    type: 'varchar',
    length: 255,
    unique: true,
    nullable: true,
  })
  googleSub!: string | null;

  // Always lowercase, so "Ben" and "ben" are one account. Null for Google
  // accounts.
  @Column({ type: 'varchar', length: 32, unique: true, nullable: true })
  username!: string | null;

  // argon2id hash. select: false keeps it out of every query that does not
  // explicitly ask for it, so it cannot leak into a response by accident.
  @Column({
    name: 'password_hash',
    type: 'text',
    nullable: true,
    select: false,
  })
  passwordHash!: string | null;

  @Column({ type: 'varchar', length: 320, nullable: true })
  email!: string | null;

  @Column({ type: 'varchar', length: 255, nullable: true })
  name!: string | null;

  @Column({ name: 'avatar_url', type: 'text', nullable: true })
  avatarUrl!: string | null;

  @CreateDateColumn({ name: 'created_at', type: 'timestamptz' })
  createdAt!: Date;

  @UpdateDateColumn({ name: 'updated_at', type: 'timestamptz' })
  updatedAt!: Date;
}
