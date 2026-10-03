# Mesma base no build e runtime para manter compatibilidade do Prisma.
ARG NODE_IMAGE=node:22-bookworm-slim
FROM ${NODE_IMAGE} AS base

WORKDIR /app

RUN apt-get update \
    && apt-get install -y --no-install-recommends openssl ca-certificates \
    && rm -rf /var/lib/apt/lists/*

FROM base AS dependencies

COPY package.json package-lock.json ./
COPY src/prisma ./src/prisma

RUN npm ci --no-audit --no-fund \
    && npx --no-install prisma generate

FROM dependencies AS build

COPY . .

ENV NX_DAEMON=false
RUN npx --no-install nx build api --configuration=production

# Imagem separada: CLI Prisma disponível somente para executar migrations.
FROM dependencies AS migrate

ENV NODE_ENV=production
USER node

CMD ["./node_modules/.bin/prisma", "migrate", "deploy"]

FROM build AS production-dependencies

RUN npm prune --omit=dev --ignore-scripts --no-audit --no-fund

FROM base AS runtime

ENV NODE_ENV=production \
    HOST=0.0.0.0 \
    PORT=3000

COPY --from=production-dependencies --chown=node:node /app/node_modules ./node_modules
COPY --from=build --chown=node:node /app/dist/api ./dist/api

USER node
EXPOSE 3000

CMD ["node", "dist/api/main.js"]
