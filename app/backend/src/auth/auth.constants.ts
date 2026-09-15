export const ACCESS_TOKEN_TTL_SECONDS = 15 * 60;
export const REFRESH_TOKEN_TTL_SECONDS = 7 * 24 * 60 * 60;

export const JWT_ISSUER = 'task-manager-backend';
export const JWT_AUDIENCE = 'task-manager';

// How long a just-rotated refresh token is still accepted without being treated
// as stolen. Parallel requests from one browser race to refresh with the same
// token; without this window the loser would log the user out everywhere.
// Injectable so tests can set it to zero.
export const REFRESH_REUSE_GRACE_MS = Symbol('REFRESH_REUSE_GRACE_MS');
export const DEFAULT_REFRESH_REUSE_GRACE_MS = 30_000;
