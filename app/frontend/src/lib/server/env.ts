// Everything under lib/server holds secrets or backend addresses. Importing it
// from a client component fails the build instead of shipping it to browsers.
import 'server-only';

export interface GoogleClient {
  clientId: string;
  clientSecret: string;
}

export interface ServerEnv {
  /** Public origin of this app, e.g. http://localhost:3000. */
  appUrl: string;
  backendUrl: string;
  /**
   * Null when Google sign-in is switched off. It needs HTTPS and a fixed
   * domain, so it is used locally; the AWS deployment runs without it.
   */
  google: GoogleClient | null;
}

let cached: ServerEnv | undefined;

function required(name: string): string {
  const value = process.env[name];
  if (!value) {
    throw new Error(`Missing required environment variable ${name}`);
  }
  return value;
}

function optional(name: string): string | null {
  return process.env[name] || null;
}

// Read on first use at request time, never at build time: the same image runs
// in every environment, so nothing environment-specific may be baked into it.
export function serverEnv(): ServerEnv {
  if (!cached) {
    const clientId = optional('GOOGLE_CLIENT_ID');
    const clientSecret = optional('GOOGLE_CLIENT_SECRET');
    cached = {
      appUrl: new URL(required('APP_URL')).origin,
      backendUrl: required('BACKEND_URL'),
      google: clientId && clientSecret ? { clientId, clientSecret } : null,
    };
  }
  return cached;
}
