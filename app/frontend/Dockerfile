# Two stages so neither the build toolchain nor npm reaches the runtime image.
# npm's own bundled dependencies (brace-expansion, ip-address, tar) are
# HIGH-severity findings that the Jenkinsfile's Trivy gate rejects, and the
# standalone server only needs node to run.

FROM node:24-alpine AS build
WORKDIR /app
ENV NEXT_TELEMETRY_DISABLED=1
COPY package*.json ./
RUN npm ci
COPY . .
# Nothing environment-specific is baked in: APP_URL, BACKEND_URL and the
# Google credentials are all read at runtime, so one image runs everywhere.
RUN npm run build

# node:18-alpine was end-of-life (April 2025) and carried 37 fixable
# HIGH/CRITICAL CVEs. Node 24 + apk upgrade (libcrypto3/libssl3) + dropping
# npm brings the image to zero, verified with the same trivy flags CI uses.
FROM node:24-alpine
RUN apk --no-cache upgrade && rm -rf /usr/local/lib/node_modules/npm /usr/local/bin/npm /usr/local/bin/npx
ENV NODE_ENV=production \
    NEXT_TELEMETRY_DISABLED=1 \
    PORT=3000 \
    HOSTNAME=0.0.0.0
WORKDIR /app
# output: 'standalone' traces only the files the server needs, including a
# minimal node_modules. Static assets are not part of the trace.
COPY --from=build /app/.next/standalone ./
COPY --from=build /app/.next/static ./.next/static
# Code stays owned by root. Only Next's runtime cache directory is writable.
RUN mkdir -p .next/cache && chown node:node .next/cache
USER node
EXPOSE 3000
CMD ["node", "server.js"]
