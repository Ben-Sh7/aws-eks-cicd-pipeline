# Three stages so neither the TypeScript toolchain nor npm reaches the runtime
# image. npm's own bundled dependencies (brace-expansion, ip-address, tar) are
# HIGH-severity findings that the Jenkinsfile's Trivy gate rejects, and the app
# only needs node to run.

# Compiles TypeScript with the dev dependencies (Nest CLI, tsc).
FROM node:24-alpine AS build
WORKDIR /app
COPY package*.json ./
RUN npm ci
COPY . .
RUN npm run build

# Production dependencies only.
FROM node:24-alpine AS deps
WORKDIR /app
COPY package*.json ./
RUN npm ci --omit=dev

# node:18-alpine was end-of-life (April 2025) and carried 37 fixable
# HIGH/CRITICAL CVEs. Node 24 + apk upgrade (libcrypto3/libssl3) + dropping
# npm brings the image to zero, verified with the same trivy flags CI uses.
FROM node:24-alpine
RUN apk --no-cache upgrade && rm -rf /usr/local/lib/node_modules/npm /usr/local/bin/npm /usr/local/bin/npx
ENV NODE_ENV=production
WORKDIR /app
# RDS enforces TLS, and the app verifies the server certificate against this
# bundle instead of disabling verification. ADD from a URL creates the file
# with mode 600, hence the chown so the node user can read it.
ADD --chown=node:node https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem /app/rds-ca.pem
# Code and dependencies stay owned by root: the process can read them but
# cannot modify its own code.
COPY --from=deps /app/node_modules ./node_modules
COPY --from=build /app/dist ./dist
COPY package.json ./
USER node
EXPOSE 3001
CMD ["node", "dist/main.js"]
