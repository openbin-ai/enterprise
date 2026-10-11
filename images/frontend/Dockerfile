# syntax=docker/dockerfile:1.7
#
# Both web apps in one nginx image. Build context is the platform checkout
# (it needs shared/ next to the two app directories); scripts/build-images.sh
# stages a clean copy and passes this file with -f.
#
# Endpoints are NOT baked in: the container writes /openbin-config.js from
# APP_HOST / APK_HOST / API_HOST / AUTH_HOST at start (entrypoint.sh), and
# the apps read window.__OPENBIN_CONFIG__ before falling back to Vite env.

FROM node:22-alpine AS build
RUN corepack enable
WORKDIR /src
COPY shared ./shared
COPY openbin-frontend ./openbin-frontend
COPY openapk-frontend ./openapk-frontend
# Unset the hosted endpoints so the fallback is never a foreign host.
RUN cd openbin-frontend \
 && rm -f .env.production \
 && pnpm install --frozen-lockfile \
 && pnpm build
RUN cd openapk-frontend \
 && rm -f .env.production \
 && pnpm install --frozen-lockfile \
 && pnpm build

FROM nginx:1.27-alpine
RUN rm -f /etc/nginx/conf.d/default.conf \
 && mkdir -p /run/openbin/downloads /usr/share/openbin/downloads
COPY --from=build /src/openbin-frontend/dist /usr/share/nginx/html/openbin
COPY --from=build /src/openapk-frontend/dist /usr/share/nginx/html/openapk
COPY images/frontend/nginx.conf /etc/nginx/conf.d/openbin.conf
COPY images/frontend/site-common.conf /etc/nginx/openbin-common.conf
COPY images/frontend/entrypoint.sh /docker-entrypoint.d/40-openbin-config.sh
RUN chmod +x /docker-entrypoint.d/40-openbin-config.sh
EXPOSE 8080 8081
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD wget -qO- http://localhost:8080/healthz >/dev/null || exit 1
