'use client';

import Image from 'next/image';
import { useState } from 'react';
import type { UserProfile } from '@/lib/tasks';

export function UserMenu({ user }: { user: UserProfile | null }) {
  const [signingOut, setSigningOut] = useState(false);

  async function signOut() {
    setSigningOut(true);
    try {
      await fetch('/api/auth/logout', { method: 'POST' });
    } finally {
      // A full page load, so nothing from the signed-out session stays in memory.
      // eslint-disable-next-line @next/next/no-location-assign-relative-destination
      window.location.assign('/login');
    }
  }

  return (
    <div className="flex items-center gap-3">
      {user?.avatarUrl && (
        // unoptimized: served straight from Google, not proxied through the
        // image optimizer. no-referrer: Google's avatar CDN can reject
        // requests that carry a referrer.
        <Image
          src={user.avatarUrl}
          alt=""
          width={32}
          height={32}
          unoptimized
          referrerPolicy="no-referrer"
          className="h-8 w-8 rounded-full"
        />
      )}
      {user && (
        <span className="hidden text-sm text-slate-600 sm:inline">
          {user.name ?? user.username ?? user.email}
        </span>
      )}
      <button
        type="button"
        onClick={signOut}
        disabled={signingOut}
        className="rounded-lg px-3 py-1.5 text-sm font-medium text-slate-600 hover:bg-slate-200 disabled:opacity-50"
      >
        {signingOut ? 'Signing out…' : 'Sign out'}
      </button>
    </div>
  );
}
