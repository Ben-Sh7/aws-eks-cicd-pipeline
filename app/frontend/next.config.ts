import type { NextConfig } from 'next';

const isDev = process.env.NODE_ENV === 'development';

// A baseline Content-Security-Policy. Next's inline bootstrap scripts need
// 'unsafe-inline' unless nonces are generated per request; 'unsafe-eval' is
// only for the dev server's hot reload. Images are limited to this app and
// Google's avatar CDN, and the app can never be framed.
const contentSecurityPolicy = [
  "default-src 'self'",
  `script-src 'self' 'unsafe-inline'${isDev ? " 'unsafe-eval'" : ''}`,
  "style-src 'self' 'unsafe-inline'",
  "img-src 'self' data: https://lh3.googleusercontent.com",
  "font-src 'self'",
  "connect-src 'self'",
  "object-src 'none'",
  "base-uri 'self'",
  "form-action 'self'",
  "frame-ancestors 'none'",
].join('; ');

const nextConfig: NextConfig = {
  // A self-contained server.js with only the traced dependencies - small
  // image, no npm at runtime.
  output: 'standalone',
  // Pinned to this directory. Otherwise Next infers the root from the nearest
  // lockfile, which can be one outside the repo, and the standalone output
  // then nests server.js under that path instead of at its top level.
  turbopack: { root: __dirname },
  outputFileTracingRoot: __dirname,
  poweredByHeader: false,
  async headers() {
    return [
      {
        source: '/:path*',
        headers: [
          { key: 'Content-Security-Policy', value: contentSecurityPolicy },
          { key: 'X-Content-Type-Options', value: 'nosniff' },
          { key: 'Referrer-Policy', value: 'strict-origin-when-cross-origin' },
          {
            key: 'Permissions-Policy',
            value: 'camera=(), microphone=(), geolocation=()',
          },
        ],
      },
    ];
  },
};

export default nextConfig;
