# syntax=docker/dockerfile:1.7
#
# MinIO server + mc client, compiled from the upstream source tags.
#
# MinIO stopped publishing community container images and binaries in 2025
# (Docker Hub, Quay and dl.min.io all return nothing), while the AGPL-3.0
# source and its release tags remain on GitHub. The distribution therefore
# builds its own image: pinned tags, reproducible, unmodified upstream code.
#
# Server:  default entrypoint, `server /data`
# Client:  --entrypoint mc   (minio-init, backup and restore use this)

ARG GO_IMAGE=golang:1.24-alpine

FROM ${GO_IMAGE} AS build
ARG MINIO_RELEASE=RELEASE.2025-09-07T16-13-09Z
ARG MC_RELEASE=RELEASE.2025-04-16T18-13-26Z
RUN apk add --no-cache git ca-certificates
ENV CGO_ENABLED=0 GOFLAGS=-trimpath
WORKDIR /src
RUN git clone --quiet --depth 1 --branch "${MINIO_RELEASE}" https://github.com/minio/minio.git minio \
 && cd minio \
 && go build -tags kqueue -ldflags "-s -w -X github.com/minio/minio/cmd.Version=${MINIO_RELEASE} -X github.com/minio/minio/cmd.ReleaseTag=${MINIO_RELEASE}" -o /out/minio .
RUN git clone --quiet --depth 1 --branch "${MC_RELEASE}" https://github.com/minio/mc.git mc \
 && cd mc \
 && go build -ldflags "-s -w -X github.com/minio/mc/cmd.Version=${MC_RELEASE} -X github.com/minio/mc/cmd.ReleaseTag=${MC_RELEASE}" -o /out/mc .

FROM alpine:3.21
RUN apk add --no-cache ca-certificates curl \
 && addgroup -S -g 1000 minio && adduser -S -u 1000 -G minio -h /data minio \
 && mkdir -p /data && chown minio:minio /data
COPY --from=build /out/minio /usr/local/bin/minio
COPY --from=build /out/mc /usr/local/bin/mc
USER minio
VOLUME /data
EXPOSE 9000
HEALTHCHECK --interval=15s --timeout=5s --start-period=10s --retries=5 \
  CMD curl -fsS http://localhost:9000/minio/health/live >/dev/null || exit 1
ENTRYPOINT ["/usr/local/bin/minio"]
CMD ["server", "/data"]
