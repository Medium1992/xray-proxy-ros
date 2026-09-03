# syntax=docker/dockerfile:1.7
FROM --platform=$BUILDPLATFORM alpine:latest AS package
ARG TARGETOS
ARG TARGETARCH
ARG TARGETVARIANT
ARG XRAY_RELEASE_TAG=latest
ARG XRAY_RELEASE_REPO=XTLS/Xray-core
RUN apk add --no-cache curl jq unzip
RUN mkdir -p /final/usr/local/bin

RUN --mount=type=secret,id=gh_token set -eu; \
    gh_api() { \
      if [ -s /run/secrets/gh_token ]; then \
        curl -fsSL --retry 5 --retry-all-errors --retry-delay 3 -H "Authorization: Bearer $(cat /run/secrets/gh_token)" "$@"; \
      else \
        curl -fsSL --retry 5 --retry-all-errors --retry-delay 3 "$@"; \
      fi; \
    }; \
    if [ "$XRAY_RELEASE_TAG" = "latest" ]; then \
      XRAY_RELEASE_API="https://api.github.com/repos/${XRAY_RELEASE_REPO}/releases/latest"; \
    else \
      XRAY_RELEASE_API="https://api.github.com/repos/${XRAY_RELEASE_REPO}/releases/tags/${XRAY_RELEASE_TAG}"; \
    fi; \
    if [ "$TARGETARCH" = "amd64" ]; then \
      ASSET="Xray-linux-64.zip"; \
    elif [ "$TARGETARCH" = "arm64" ]; then \
      ASSET="Xray-linux-arm64-v8a.zip"; \
    elif [ "$TARGETARCH" = "arm" ] && [ "$TARGETVARIANT" = "v7" ]; then \
      ASSET="Xray-linux-arm32-v7a.zip"; \
    else \
      ASSET="Xray-linux-arm32-v5.zip"; \
    fi; \
    RELEASE_JSON="$(gh_api "$XRAY_RELEASE_API")"; \
    URL="$(printf '%s' "$RELEASE_JSON" | jq -r --arg asset "$ASSET" '.assets[] | select(.name == $asset) | .browser_download_url' | head -n1)"; \
    [ -n "$URL" ] && [ "$URL" != "null" ] || { echo "Xray asset $ASSET not found in $XRAY_RELEASE_API" >&2; exit 1; }; \
    curl -fL --retry 5 --retry-all-errors --retry-delay 3 "$URL" -o /tmp/xray.zip; \
    mkdir -p /tmp/xray; \
    unzip -q /tmp/xray.zip -d /tmp/xray; \
    install -m 0755 /tmp/xray/xray /final/usr/local/bin/xray
    
COPY entrypoint.sh entrypoint_armv5.sh /final/

RUN if [ "$TARGETARCH" = "arm" ] && [ "$TARGETVARIANT" = "v5" ]; then \
        mv /final/entrypoint_armv5.sh /final/entrypoint.sh; \
    else \
        rm -f /final/entrypoint_armv5.sh; \
    fi && \
    chmod +x /final/entrypoint.sh /final/usr/local/bin/xray

FROM --platform=linux/amd64 alpine:latest AS linux-amd64
FROM --platform=linux/arm64 alpine:latest AS linux-arm64
FROM --platform=linux/arm/v7 alpine:latest AS linux-armv7
FROM --platform=linux/arm/v5 scratch AS linux-armv5
ADD rootfs.tar /

FROM ${TARGETOS}-${TARGETARCH}${TARGETVARIANT}
ARG TARGETARCH
ARG TARGETVARIANT

COPY --from=package /final /

RUN if [ "$TARGETARCH" = "arm64" ] || [ "$TARGETARCH" = "amd64" ]; then \
        apk add --no-cache ca-certificates tzdata iproute2 nftables jq; \
    elif [ "$TARGETARCH" = "arm" ] && [ "$TARGETVARIANT" = "v7" ]; then \
        apk add --no-cache ca-certificates tzdata iproute2 iptables iptables-legacy jq; \
    fi && \
    if [ "$TARGETARCH" = "arm" ] && [ "$TARGETVARIANT" = "v7" ]; then \
    rm -f /usr/sbin/iptables /usr/sbin/iptables-save /usr/sbin/iptables-restore && \
    ln -s /usr/sbin/iptables-legacy /usr/sbin/iptables && \
    ln -s /usr/sbin/iptables-legacy-save /usr/sbin/iptables-save && \
    ln -s /usr/sbin/iptables-legacy-restore /usr/sbin/iptables-restore; \
    fi

ENTRYPOINT ["/entrypoint.sh"]
