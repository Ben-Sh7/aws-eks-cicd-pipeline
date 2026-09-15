'use client';

import { type FormEvent, useState } from 'react';
import { messageFrom } from '@/lib/api-client';

// Mirrors the backend's rules (app/backend/src/auth/dto/credentials.ts) so the
// browser can reject obvious mistakes early. The backend still enforces them.
const PASSWORD_MIN_LENGTH = 12;
const PASSWORD_MAX_LENGTH = 128;
const USERNAME_MAX_LENGTH = 32;

type Mode = 'login' | 'register';

const inputClass =
  'w-full rounded-lg border border-slate-300 bg-white px-3 py-2 text-sm focus:border-indigo-500 focus:outline-none focus:ring-2 focus:ring-indigo-200';

export function PasswordForm() {
  const [mode, setMode] = useState<Mode>('login');
  const [username, setUsername] = useState('');
  const [password, setPassword] = useState('');
  const [name, setName] = useState('');
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const registering = mode === 'register';

  function switchMode() {
    setMode(registering ? 'login' : 'register');
    setError(null);
  }

  async function handleSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setSubmitting(true);
    setError(null);
    try {
      const body = registering
        ? { username, password, ...(name.trim() ? { name: name.trim() } : {}) }
        : { username, password };
      // Plain fetch rather than apiFetch: a 401 here means "wrong password",
      // not "session ended", and must not redirect.
      const response = await fetch(`/api/auth/password/${mode}`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(body),
      });
      if (response.ok) {
        // A full page load, so the app starts fresh with the new session.
        // eslint-disable-next-line @next/next/no-location-assign-relative-destination
        window.location.assign('/');
        return;
      }
      const errorBody: unknown = await response.json().catch(() => null);
      setError(
        messageFrom(
          errorBody,
          response.status === 429
            ? 'Too many attempts. Please wait a minute and try again.'
            : 'Something went wrong. Please try again.',
        ),
      );
    } catch {
      setError('The server is unavailable. Please try again.');
    } finally {
      setSubmitting(false);
    }
  }

  return (
    <form onSubmit={handleSubmit} className="space-y-3 text-left">
      <label className="block text-xs font-medium text-slate-600">
        Username
        <input
          className={`${inputClass} mt-1`}
          value={username}
          onChange={(event) => setUsername(event.target.value)}
          autoComplete="username"
          autoCapitalize="none"
          spellCheck={false}
          maxLength={USERNAME_MAX_LENGTH}
          required
        />
      </label>

      {registering && (
        <label className="block text-xs font-medium text-slate-600">
          Display name <span className="font-normal text-slate-400">(optional)</span>
          <input
            className={`${inputClass} mt-1`}
            value={name}
            onChange={(event) => setName(event.target.value)}
            autoComplete="name"
            maxLength={100}
          />
        </label>
      )}

      <label className="block text-xs font-medium text-slate-600">
        Password
        <input
          type="password"
          className={`${inputClass} mt-1`}
          value={password}
          onChange={(event) => setPassword(event.target.value)}
          autoComplete={registering ? 'new-password' : 'current-password'}
          minLength={registering ? PASSWORD_MIN_LENGTH : undefined}
          maxLength={PASSWORD_MAX_LENGTH}
          required
        />
        {registering && (
          <span className="mt-1 block font-normal text-slate-400">
            At least {PASSWORD_MIN_LENGTH} characters. A few random words work well.
          </span>
        )}
      </label>

      {error && (
        <p role="alert" className="rounded-lg bg-red-50 px-3 py-2 text-sm text-red-700">
          {error}
        </p>
      )}

      <button
        type="submit"
        disabled={submitting}
        className="w-full rounded-lg bg-indigo-600 px-4 py-3 font-medium text-white hover:bg-indigo-700 disabled:cursor-not-allowed disabled:opacity-50"
      >
        {submitting ? 'Please wait…' : registering ? 'Create account' : 'Sign in'}
      </button>

      <p className="text-center text-sm text-slate-500">
        {registering ? 'Already have an account?' : "Don't have an account?"}{' '}
        <button
          type="button"
          onClick={switchMode}
          className="font-medium text-indigo-600 hover:underline"
        >
          {registering ? 'Sign in' : 'Create one'}
        </button>
      </p>
    </form>
  );
}
