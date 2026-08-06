FROM --platform=$BUILDPLATFORM alpine:latest AS authelia_downloader
ARG TARGETARCH

RUN apk update && apk add --no-cache curl tar xz jq
# You can pin a version here or use 'latest' logic
RUN AUTHELIA_VERSION=$(curl -s https://api.github.com/repos/authelia/authelia/releases/latest | jq -r .tag_name)
RUN AUTHELIA_ARCH=${TARGETARCH}

RUN curl -L -o /tmp/authelia.tar.gz "https://github.com/authelia/authelia/releases/download/${AUTHELIA_VERSION}/authelia-${AUTHELIA_VERSION}-linux-${AUTHELIA_ARCH}-musl.tar.gz" && \
	mkdir -p /tmp/authelia && \
    tar -xzf /tmp/authelia.tar.gz -C /tmp/authelia/

# Download s6-overlay
RUN S6_VER=$(curl -s https://api.github.com/repos/just-containers/s6-overlay/releases/latest | jq -r .tag_name)
RUN case "${TARGETARCH}" in \
        "amd64")  S6_ARCH="x86_64" ;; \
        "arm64")  S6_ARCH="aarch64" ;; \
        "arm")    S6_ARCH="armhf" ;; \
        "386")    S6_ARCH="i686" ;; \
        *)        S6_ARCH="${TARGETARCH}" ;; \
    esac
# Download and extract the noarch scripts
ADD https://github.com/just-containers/s6-overlay/releases/download/${S6_VER}/s6-overlay-noarch.tar.xz /tmp
RUN mkdir -p /tmp/s6-overlay && \
	tar -C /tmp/s6-overlay/ -Jxpf /tmp/s6-overlay-noarch.tar.xz

# Download and extract the architecture-specific binaries
ADD https://github.com/just-containers/s6-overlay/releases/download/${S6_VER}/s6-overlay-${S6_ARCH}.tar.xz /tmp
RUN tar -C /tmp/s6-overlay/ -Jxpf /tmp/s6-overlay-${S6_ARCH}.tar.xz

FROM lldap/lldap:latest AS lldap_bin
FROM inbucket/inbucket:latest AS inbucket_bin

#ARG CADDY=serfriz/caddy-cloudflare:latest
ARG CADDY=serfriz/caddy-cloudflare-crowdsec:latest

FROM ${CADDY:-caddy:alpine}

# Install core tools
RUN apk add --no-cache tzdata bash wget && rm -f /var/log/apk.log

# Setup appuser
RUN addgroup -S -g 1000 appuser && \
    adduser -S -u 1000 -G appuser appuser

# Copy Binaries & Assets
COPY --from=authelia_downloader /tmp/authelia/authelia /usr/bin/authelia
COPY --from=authelia_downloader /tmp/s6-overlay /
COPY --from=inbucket_bin /opt/inbucket /opt/inbucket
RUN ln -s /opt/inbucket/bin/inbucket /usr/bin/inbucket
COPY --from=lldap_bin /app /app
RUN ln -s /app/lldap /usr/bin/lldap
RUN ln -s /app/lldap_migration_tool /usr/bin/lldap_migration_tool
RUN ln -s /app/lldap_set_password /usr/bin/lldap_set_password


# Inbucket Configuration
ENV INBUCKET_SMTP_DISCARDDOMAINS=bitbucket.local
ENV INBUCKET_SMTP_TIMEOUT=30s
ENV INBUCKET_POP3_TIMEOUT=30s
ENV INBUCKET_WEB_GREETINGFILE=/config/inbucket/greeting.html
ENV INBUCKET_WEB_COOKIEAUTHKEY=secret-inbucket-session-cookie-key
ENV INBUCKET_WEB_UIDIR=/opt/inbucket/ui
ENV INBUCKET_STORAGE_TYPE=file
ENV INBUCKET_STORAGE_PARAMS=path:/data/inbucket
ENV INBUCKET_STORAGE_RETENTIONPERIOD=72h
ENV INBUCKET_STORAGE_MAILBOXMSGCAP=300
# Authelia
ENV X_AUTHELIA_CONFIG=/config/authelia/configuration.yml
# LLDAP log to warn
ENV RUST_LOG=lldap=warn,warp=warn,hyper=warn,sqlx=warn

# Capabilities and s6 Config
COPY s6-rc.d /etc/s6-overlay/s6-rc.d

COPY healthcheck.sh /usr/local/bin/healthcheck.sh
HEALTHCHECK --interval=30s --timeout=10s --start-period=1m --retries=3 CMD /usr/local/bin/healthcheck.sh

ENTRYPOINT ["/init"]
