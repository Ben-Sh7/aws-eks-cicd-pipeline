import { PasswordForm } from '@/components/password-form';
import { serverEnv } from '@/lib/server/env';

const ERROR_MESSAGES: Record<string, string> = {
  session_expired: 'The sign-in took too long. Please try again.',
  google_sign_in_failed: 'Google sign-in did not complete. Please try again.',
  google_unavailable: 'Google sign-in is unavailable right now. Please try again shortly.',
  google_disabled: 'Google sign-in is not enabled here. Use a username and password.',
  sign_in_rejected: 'Your Google account could not be verified.',
  server_unavailable: 'The server is unavailable. Please try again shortly.',
};

interface LoginPageProps {
  searchParams: Promise<{ error?: string | string[] }>;
}

export default async function LoginPage({ searchParams }: LoginPageProps) {
  const { error } = await searchParams;
  const message =
    typeof error === 'string'
      ? (ERROR_MESSAGES[error] ?? 'Sign-in failed. Please try again.')
      : null;
  // Decided per request from the runtime settings: the same image runs with
  // Google sign-in locally and without it on AWS.
  const googleEnabled = serverEnv().google !== null;

  return (
    <main className="flex min-h-screen items-center justify-center p-6">
      <div className="w-full max-w-sm rounded-2xl bg-white p-8 text-center shadow-lg">
        <h1 className="text-2xl font-semibold">Task Manager</h1>
        <p className="mt-2 text-sm text-slate-500">
          Sign in to see and organize your tasks.
        </p>

        {message && (
          <p
            role="alert"
            className="mt-6 rounded-lg bg-red-50 px-4 py-3 text-sm text-red-700"
          >
            {message}
          </p>
        )}

        {googleEnabled && (
          <>
            {/* A plain link, not next/link: it must be a full navigation to a
                route handler that redirects to Google, and must never be
                prefetched. */}
            <a
              href="/api/auth/login"
              className="mt-8 flex w-full items-center justify-center gap-3 rounded-lg border border-slate-300 bg-white px-4 py-3 font-medium text-slate-700 transition hover:bg-slate-50 focus:outline-none focus-visible:ring-2 focus-visible:ring-indigo-500"
            >
              <GoogleLogo />
              Sign in with Google
            </a>

            <div className="my-6 flex items-center gap-3 text-xs uppercase text-slate-400">
              <span className="h-px flex-1 bg-slate-200" />
              or
              <span className="h-px flex-1 bg-slate-200" />
            </div>
          </>
        )}

        <div className={googleEnabled ? undefined : 'mt-8'}>
          <PasswordForm />
        </div>
      </div>
    </main>
  );
}

function GoogleLogo() {
  return (
    <svg aria-hidden="true" viewBox="0 0 48 48" className="h-5 w-5">
      <path
        fill="#FFC107"
        d="M43.6 20.5H42V20H24v8h11.3C33.7 32.7 29.2 36 24 36c-6.6 0-12-5.4-12-12s5.4-12 12-12c3.1 0 5.8 1.2 7.9 3.1l5.7-5.7C34 6.1 29.3 4 24 4 12.9 4 4 12.9 4 24s8.9 20 20 20 20-8.9 20-20c0-1.3-.1-2.4-.4-3.5z"
      />
      <path
        fill="#FF3D00"
        d="M6.3 14.7l6.6 4.8C14.7 15.1 19 12 24 12c3.1 0 5.8 1.2 7.9 3.1l5.7-5.7C34 6.1 29.3 4 24 4 16.3 4 9.7 8.3 6.3 14.7z"
      />
      <path
        fill="#4CAF50"
        d="M24 44c5.2 0 9.9-2 13.4-5.2l-6.2-5.2C29.2 35.1 26.7 36 24 36c-5.2 0-9.6-3.3-11.3-8l-6.5 5C9.5 39.6 16.2 44 24 44z"
      />
      <path
        fill="#1976D2"
        d="M43.6 20.5H42V20H24v8h11.3c-.8 2.2-2.2 4.2-4.1 5.6l6.2 5.2C37 38.3 44 33 44 24c0-1.3-.1-2.4-.4-3.5z"
      />
    </svg>
  );
}
