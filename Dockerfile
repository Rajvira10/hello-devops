# syntax=docker/dockerfile:1.7

# ---------------------------------------------------------------------------
# Build stage: compile a static binary. Runs on the *build* platform and
# cross-compiles for the target, so multi-arch builds need no QEMU emulation.
# ---------------------------------------------------------------------------
FROM --platform=$BUILDPLATFORM golang:1.27.3-alpine3.24@sha256:fa3d596898d9f126af7c01d14ee7597bab3f39cccf392ef36b69fe77cd681f18 AS build

WORKDIR /src

# Dependencies first: this layer is cached until go.mod/go.sum change.
COPY app/go.mod app/go.sum ./
RUN --mount=type=cache,target=/go/pkg/mod \
    go mod download

COPY app/ ./

ARG TARGETOS=linux
ARG TARGETARCH=amd64
ARG VERSION=dev
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH \
    go build -trimpath -ldflags="-s -w -X main.version=${VERSION}" \
      -o /out/server ./cmd/server

# ---------------------------------------------------------------------------
# Runtime stage: distroless static (no shell, no package manager, CA certs +
# tzdata only). The :nonroot variant runs as UID/GID 65532.
# ---------------------------------------------------------------------------
FROM gcr.io/distroless/static-debian13:nonroot@sha256:25ac8f0c3b2334a9eb05452266bd4697864a8c8ef0ef71e5e6480d7f92868329

ARG VERSION=dev
ARG REVISION=unknown
ARG CREATED=unknown
LABEL org.opencontainers.image.title="hello-devops" \
      org.opencontainers.image.description="Small Go web service used for the DevOps assessment" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.revision="${REVISION}" \
      org.opencontainers.image.created="${CREATED}" \
      org.opencontainers.image.source="https://github.com/Rajvira10/hello-devops" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.base.name="gcr.io/distroless/static-debian13:nonroot"

COPY --from=build /out/server /server

ENV PORT=8080 \
    LOG_LEVEL=info \
    APP_ENV=production

USER 65532:65532
EXPOSE 8080

# Distroless has no curl/wget, so the binary probes itself.
HEALTHCHECK --interval=15s --timeout=3s --start-period=5s --retries=3 \
  CMD ["/server", "healthcheck"]

ENTRYPOINT ["/server"]
