import type { TransformFnParams } from 'class-transformer';

// 3-32 characters of letters, digits, dot, dash or underscore, starting and
// ending with a letter or digit. Checked after lowercasing.
export const USERNAME_PATTERN = /^[a-z0-9][a-z0-9._-]{1,30}[a-z0-9]$/;
export const USERNAME_MAX_LENGTH = 32;

// NIST SP 800-63B: length is what makes a password strong; composition rules
// ("one digit, one symbol") are not. The upper bound caps how much hashing
// work a single request can force.
export const PASSWORD_MIN_LENGTH = 12;
export const PASSWORD_MAX_LENGTH = 128;

// Usernames are case-insensitive: stored and looked up in lowercase.
export const normalizeUsername = ({ value }: TransformFnParams): unknown =>
  typeof value === 'string' ? value.trim().toLowerCase() : value;

export const trim = ({ value }: TransformFnParams): unknown =>
  typeof value === 'string' ? value.trim() : value;
