# syntax=docker/dockerfile:1.7
#
# usque — MASQUE-клиент Cloudflare WARP в контейнере.
# Мультиарх: amd64 / arm64 / armv7 собираются кросс-компиляцией Go (CGO_ENABLED=0),
# поэтому QEMU/binfmt НЕ нужен — образ для чужой архитектуры собирается нативно.
#
# Сборка:  docker build -t usque:local .
#          docker buildx build --platform linux/amd64,linux/arm64 -t usque:multi .

ARG GO_IMAGE=golang:1.26.3-alpine
ARG ALPINE_IMAGE=alpine:3.22

# ---------- стадия сборки ----------
FROM --platform=$BUILDPLATFORM ${GO_IMAGE} AS build

ARG TARGETOS
ARG TARGETARCH
ARG TARGETVARIANT
ARG USQUE_REPO=https://github.com/Diniboy1123/usque.git
ARG USQUE_REF=main

RUN apk add --no-cache git ca-certificates

WORKDIR /src

# Клонируем апстрим. Работает и для ветки, и для тега, и для конкретного коммита.
RUN set -eux; \
    if ! git clone --depth 1 --branch "${USQUE_REF}" "${USQUE_REPO}" . 2>/dev/null; then \
        rm -rf /src/* /src/.[!.]* 2>/dev/null || true; \
        git clone "${USQUE_REPO}" .; \
        git checkout "${USQUE_REF}"; \
    fi; \
    rm -rf .git -f 2>/dev/null || true

RUN --mount=type=cache,target=/go/pkg/mod \
    go mod download

RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    set -eux; \
    GOARM=""; \
    if [ "${TARGETARCH}" = "arm" ]; then GOARM="${TARGETVARIANT#v}"; [ -n "${GOARM}" ] || GOARM=7; fi; \
    CGO_ENABLED=0 GOOS="${TARGETOS}" GOARCH="${TARGETARCH}" GOARM="${GOARM}" \
    go build -trimpath \
        -ldflags "-s -w -X github.com/Diniboy1123/usque/cmd.version=${USQUE_REF}" \
        -o /out/usque .; \
    file /out/usque 2>/dev/null || true; \
    /out/usque version 2>/dev/null || true

# ---------- стадия выполнения ----------
FROM ${ALPINE_IMAGE}

# iproute2 нужен для ip/ss, bash — для entrypoint и хуков, jq — для проверки конфига,
# ca-certificates — для TLS к API Cloudflare при register/enroll.
RUN apk add --no-cache \
        ca-certificates \
        iproute2 \
        bash \
        jq \
        tzdata \
        curl

COPY --from=build /out/usque /usr/local/bin/usque
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY healthcheck.sh /usr/local/bin/healthcheck.sh
COPY hooks/route-hook.sh /usr/local/share/usque/hooks/route-hook.sh

RUN chmod 0755 /usr/local/bin/entrypoint.sh \
              /usr/local/bin/healthcheck.sh \
              /usr/local/share/usque/hooks/route-hook.sh \
    && mkdir -p /etc/usque /run/usque \
    && usque version

# Конфиг по умолчанию; каталог монтируется томом (./config:/etc/usque)
ENV USQUE_CONFIG=/etc/usque/config.json

WORKDIR /etc/usque

HEALTHCHECK --interval=30s --timeout=5s --start-period=25s --retries=3 \
    CMD ["/usr/local/bin/healthcheck.sh"]

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD []
