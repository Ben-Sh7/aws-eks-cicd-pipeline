// Browser-side calls to this app's own /api routes. The browser never talks to
// the backend directly and never sees a token: the route handlers attach it
// from an httpOnly cookie.

export class ApiError extends Error {
  constructor(
    readonly status: number,
    message: string,
  ) {
    super(message);
  }
}

// Nest error bodies carry `message` as a string or, for validation errors, a
// list of strings.
export function messageFrom(body: unknown, fallback: string): string {
  if (body && typeof body === 'object' && 'message' in body) {
    const { message } = body as { message: unknown };
    if (typeof message === 'string') {
      return message;
    }
    if (Array.isArray(message)) {
      return message.join('. ');
    }
  }
  return fallback;
}

export function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : 'Something went wrong';
}

export async function apiFetch<T>(path: string, init?: RequestInit): Promise<T> {
  const response = await fetch(path, {
    ...init,
    headers: init?.body
      ? { 'Content-Type': 'application/json', ...init.headers }
      : init?.headers,
  });

  if (response.status === 401) {
    // The session is gone (expired, revoked, or signed out elsewhere). A full
    // page load, not a client-side route change, so no state from the ended
    // session survives in memory.
    // eslint-disable-next-line @next/next/no-location-assign-relative-destination
    window.location.assign('/login');
    throw new ApiError(401, 'Your session has ended. Please sign in again.');
  }
  if (!response.ok) {
    const body: unknown = await response.json().catch(() => null);
    throw new ApiError(
      response.status,
      messageFrom(body, `Request failed (${response.status})`),
    );
  }
  if (response.status === 204) {
    return undefined as T;
  }
  return (await response.json()) as T;
}
