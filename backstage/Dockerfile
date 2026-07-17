FROM node:20-bookworm-slim AS build

RUN apt-get update && \
    apt-get install -y --no-install-recommends ca-certificates python3 g++ build-essential && \
    rm -rf /var/lib/apt/lists/* && \
    yarn config set python /usr/bin/python3

RUN mkdir -p /app /etc/tls && chown node:node /app /etc/tls

USER node
WORKDIR /app

COPY --chown=node:node . .

RUN cp etc/tls/tls.key etc/tls/tls.crt /etc/tls/

RUN yarn install --frozen-lockfile --network-timeout 300000

RUN yarn catalog:validate

RUN CI=true yarn workspace backend test --runInBand src/extensions/platformDeliveryActions.test.ts

RUN yarn build:backend

FROM node:20-bookworm-slim

# Install isolate-vm dependencies, these are needed by the @backstage/plugin-scaffolder-backend.
RUN apt-get update && \
    apt-get install -y --no-install-recommends ca-certificates python3 g++ build-essential && \
    rm -rf /var/lib/apt/lists/* && \
    yarn config set python /usr/bin/python3

# Install sqlite3 dependencies. You can skip this if you don't use sqlite3 in the image,
# in which case you should also move better-sqlite3 to "devDependencies" in package.json.
RUN apt-get update && \
    apt-get install -y --no-install-recommends libsqlite3-dev && \
    rm -rf /var/lib/apt/lists/*

# From here on we use the least-privileged `node` user to run the backend.
RUN mkdir -p /app && chown node:node /app
USER node

# This should create the app dir as `node`.
# If it is instead created as `root` then the `tar` command below will
# fail: `can't create directory 'packages/': Permission denied`.
# If this occurs, then ensure BuildKit is enabled (`DOCKER_BUILDKIT=1`)
# so the app dir is correctly created as `node`.
WORKDIR /app

# This switches many Node.js dependencies to production mode.
ENV NODE_ENV=production

# Copy repo skeleton first, to avoid unnecessary docker cache invalidation.
# The skeleton contains the package.json of each package in the monorepo,
# and along with yarn.lock and the root package.json, that's enough to run yarn install.
COPY --from=build --chown=node:node /app/yarn.lock /app/package.json /app/packages/backend/dist/skeleton.tar.gz ./
RUN tar xzf skeleton.tar.gz && rm skeleton.tar.gz

RUN yarn install --frozen-lockfile --production --network-timeout 300000

# Then copy the rest of the backend bundle, along with any other files we might want.
COPY --from=build --chown=node:node /app/packages/backend/dist/bundle.tar.gz /app/app-config.yaml ./
RUN tar xzf bundle.tar.gz && rm bundle.tar.gz

# Copy the examples directory to the same folder as frontend and backend
COPY --from=build --chown=node:node /app/packages/examples ./examples
COPY --from=build --chown=node:node /app/packages/templates ./templates

ENV NODE_EXTRA_CA_CERTS=/etc/tls/tls.crt
ENV NODE_OPTIONS=--no-node-snapshot

RUN printenv

CMD ["node", "packages/backend", "--config", "app-config.yaml"]