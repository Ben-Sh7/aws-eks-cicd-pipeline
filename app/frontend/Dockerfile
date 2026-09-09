# Two stages so npm never reaches the runtime image: npm's own bundled
# dependencies (brace-expansion, ip-address, tar) are HIGH-severity findings
# that the Jenkinsfile's Trivy gate rejects, and the app does not need npm to
# run - package.json's start script is just "node server.js".
FROM node:24-alpine AS deps
WORKDIR /app
COPY package*.json ./
RUN npm ci --omit=dev

# node:18-alpine was end-of-life (April 2025) and carried 37 fixable
# HIGH/CRITICAL CVEs. Node 24 + apk upgrade (libcrypto3/libssl3) + dropping
# npm brings the image to zero, verified with the same trivy flags CI uses.
FROM node:24-alpine
RUN apk --no-cache upgrade  && rm -rf /usr/local/lib/node_modules/npm /usr/local/bin/npm /usr/local/bin/npx
WORKDIR /app
COPY --from=deps --chown=node:node /app/node_modules ./node_modules
COPY --chown=node:node . .
USER node
EXPOSE 3000
CMD ["node", "server.js"]
