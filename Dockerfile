FROM --platform=$BUILDPLATFORM alpine:latest AS package
ARG TARGETOS
ARG TARGETARCH
ARG TARGETVARIANT
ARG XRAY_RELEASE_TAG=latest
RUN apk add --no-cache curl jq unzip
RUN mkdir -p /final/usr/local/bin

RUN if [ "$XRAY_RELEASE_TAG" = "latest" ]; then \
        XRAY_RELEASE_API="https://api.github.com/repos/XTLS/Xray-core/releases/latest"; \
    else \
        XRAY_RELEASE_API="https://api.github.com/repos/XTLS/Xray-core/releases/tags/${XRAY_RELEASE_TAG}"; \
    fi && \
    curl -s "$XRAY_RELEASE_API" | \
    jq -r '.assets[].browser_download_url' | grep -E 'Xray-linux-(64.zip|arm64-v8a.zip|arm32-v7a.zip|arm32-v5.zip)' | \
    while read url; do curl -L "$url" -o "$(basename "$url")"; done

RUN for f in *.zip; do unzip "$f" -d "${f%.zip}"; done

RUN if [ "$TARGETARCH" = "amd64" ]; then mv Xray-linux-64/xray /final/usr/local/bin/xray; \
    elif [ "$TARGETARCH" = "arm64" ]; then mv Xray-linux-arm64-v8a/xray /final/usr/local/bin/xray; \
    elif [ "$TARGETARCH" = "arm" ] && [ "$TARGETVARIANT" = "v7" ]; then mv Xray-linux-arm32-v7a/xray /final/usr/local/bin/xray; \
    else mv Xray-linux-arm32-v5/xray /final/usr/local/bin/xray; fi
    
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
