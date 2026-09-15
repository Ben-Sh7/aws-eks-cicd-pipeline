import { ConflictException, Injectable } from '@nestjs/common';
import { InjectRepository } from '@nestjs/typeorm';
import { QueryFailedError, Repository } from 'typeorm';
import type { GoogleIdentity } from '../auth/google-token-verifier.service';
import { User } from './user.entity';

const UNIQUE_VIOLATION = '23505';

@Injectable()
export class UsersService {
  constructor(
    @InjectRepository(User) private readonly users: Repository<User>,
  ) {}

  // Keyed on Google's stable `sub`, not the email: an account's email can
  // change, and an address can later belong to a different account.
  async upsertFromGoogle(identity: GoogleIdentity): Promise<User> {
    await this.users.upsert(
      {
        googleSub: identity.sub,
        email: identity.email,
        name: identity.name,
        avatarUrl: identity.picture,
      },
      { conflictPaths: ['googleSub'] },
    );
    return this.users.findOneByOrFail({ googleSub: identity.sub });
  }

  // The unique constraint, not a lookup beforehand, decides whether the name
  // is free, so two simultaneous sign-ups for one name cannot both succeed.
  async createWithPassword(
    username: string,
    passwordHash: string,
    name: string | null,
  ): Promise<User> {
    try {
      return await this.users.save(
        this.users.create({ username, passwordHash, name }),
      );
    } catch (error) {
      const code = (
        error instanceof QueryFailedError
          ? (error.driverError as { code?: unknown })
          : {}
      ).code;
      if (code === UNIQUE_VIOLATION) {
        throw new ConflictException('Username is already taken');
      }
      throw error;
    }
  }

  // passwordHash is select: false on the entity, so it must be requested
  // explicitly - this is the only query that does.
  findPasswordCredentials(
    username: string,
  ): Promise<Pick<User, 'id' | 'passwordHash'> | null> {
    return this.users.findOne({
      where: { username },
      select: { id: true, passwordHash: true },
    });
  }

  findById(id: string): Promise<User | null> {
    return this.users.findOneBy({ id });
  }
}
