import { type NextRequest, NextResponse } from 'next/server';
import { REFRESH_COOKIE } from '@/lib/server/session-cookies';

// A navigation shortcut, not a security boundary: it only checks that a
// session cookie exists. The backend verifies every token, and an invalid
// session surfaces as a 401 that sends the browser to /login.
export function proxy(request: NextRequest) {
  const hasSession = request.cookies.has(REFRESH_COOKIE);
  const isLoginPage = request.nextUrl.pathname === '/login';

  if (hasSession === isLoginPage) {
    const url = request.nextUrl.clone();
    url.pathname = hasSession ? '/' : '/login';
    url.search = '';
    return NextResponse.redirect(url);
  }
  return NextResponse.next();
}

export const config = {
  matcher: ['/((?!api|_next/static|_next/image|icon.svg).*)'],
};
