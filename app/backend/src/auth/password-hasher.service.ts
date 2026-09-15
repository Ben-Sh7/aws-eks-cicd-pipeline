import { Injectable, OnModuleInit } from '@nestjs/common';
import { argon2id, hash, type HashOptions, verify } from 'argon2';
import { randomBytes } from 'node:crypto';

// OWASP Password Storage Cheat Sheet, argon2id minimum configuration: 19 MiB
// of memory, 2 iterations, 1 degree of parallelism. Memory-hard, so guessing
// at scale on GPUs is expensive, while a pod still handles several sign-ins
// at once within its 512Mi limit.
const ARGON2_OPTIONS: HashOptions = {
  type: argon2id,
  memoryCost: 19_456,
  timeCost: 2,
  parallelism: 1,
};

@Injectable()
export class PasswordHasher implements OnModuleInit {
  // A real hash of a random password, verified against when the account does
  // not exist, so a lookup miss takes as long as a wrong password.
  private dummyHash = '';

  async onModuleInit(): Promise<void> {
    this.dummyHash = await this.hash(randomBytes(32).toString('base64url'));
  }

  hash(password: string): Promise<string> {
    return hash(password, ARGON2_OPTIONS);
  }

  // The parameters and salt are read from the stored hash itself, so hashes
  // created with older settings keep verifying after the settings change.
  async verify(storedHash: string | null, password: string): Promise<boolean> {
    try {
      const matches = await verify(storedHash ?? this.dummyHash, password);
      return storedHash !== null && matches;
    } catch {
      return false;
    }
  }
}
