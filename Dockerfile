# ARG CADDY=serfriz/caddy-cloudflare-crowdsec:latest
ARG CADDY=serfriz/caddy-cloudflare:latest

FROM --platform=$BUILDPLATFORM alpine:latest AS authelia_downloader
ARG TARGETARCH

RUN apk update && apk add --no-cache curl tar xz jq

# You can pin a version here or use 'latest' logic
RUN AUTHELIA_VERSION=$(curl -s "https://api.github.com/repos/authelia/authelia/releases/latest" | jq -r .tag_name) && \
    AUTHELIA_ARCH=${TARGETARCH} && \
    curl -sL -o /tmp/authelia.tar.gz "https://github.com/authelia/authelia/releases/download/${AUTHELIA_VERSION}/authelia-${AUTHELIA_VERSION}-linux-${AUTHELIA_ARCH}-musl.tar.gz" && \
    mkdir -p /tmp/authelia && \
    tar -xzf /tmp/authelia.tar.gz -C /tmp/authelia/ && \
    chmod +x /tmp/authelia/authelia

RUN S6_VER=$(curl -s "https://api.github.com/repos/just-containers/s6-overlay/releases/latest" | jq -r .tag_name) && \
    case "${TARGETARCH}" in \
        "amd64") S6_ARCH="x86_64" ;; \
        "arm64") S6_ARCH="aarch64" ;; \
        "arm")   S6_ARCH="armhf" ;; \
        "386")   S6_ARCH="i686" ;; \
        *)       S6_ARCH="${TARGETARCH}" ;; \
    esac && \
    mkdir -p /tmp/s6-overlay && \
    curl -sSL "https://github.com/just-containers/s6-overlay/releases/download/${S6_VER}/s6-overlay-noarch.tar.xz" -o /tmp/noarch.tar.xz && \
    tar -C /tmp/s6-overlay/ -Jxpf /tmp/noarch.tar.xz && \
    curl -sSL "https://github.com/just-containers/s6-overlay/releases/download/${S6_VER}/s6-overlay-${S6_ARCH}.tar.xz" -o /tmp/bin.tar.xz && \
    tar -C /tmp/s6-overlay/ -Jxpf /tmp/bin.tar.xz

FROM lldap/lldap:latest AS lldap_bin
FROM inbucket/inbucket:latest AS inbucket_bin
FROM filebrowser/filebrowser:latest AS filebrowser_bin

FROM ${CADDY}

RUN apk add --no-cache tzdata bash wget && rm -f /var/log/apk.log

RUN addgroup -S -g 1000 appuser && \
    adduser -S -u 1000 -G appuser appuser

COPY --from=authelia_downloader /tmp/authelia/authelia /usr/bin/authelia

COPY --from=authelia_downloader /tmp/s6-overlay /

COPY --from=inbucket_bin /opt/inbucket /opt/inbucket
RUN ln -s /opt/inbucket/bin/inbucket /usr/bin/inbucket

COPY --from=lldap_bin /app /app
RUN ln -s /app/lldap /usr/bin/lldap && \
    ln -s /app/lldap_migration_tool /usr/bin/lldap_migration_tool && \
    ln -s /app/lldap_set_password /usr/bin/lldap_set_password

COPY --from=filebrowser_bin /bin/filebrowser /usr/bin/filebrowser
# RUN setcap 'cap_net_bind_service=+ep' /usr/bin/filebrowser
COPY settings.json /defaults/settings.json
RUN mkdir -p /srv && chown appuser:appuser /srv

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

ENV X_AUTHELIA_CONFIG=/config/authelia/configuration.yml
ENV X_AUTHELIA_CONFIG_FILTERS=template

# ENV RUST_LOG=lldap=warn,warp=warn,hyper=warn,sqlx=warn

COPY s6-rc.d /etc/s6-overlay/s6-rc.d
RUN chmod +x /etc/s6-overlay/s6-rc.d/*/up /etc/s6-overlay/s6-rc.d/*/run

COPY healthcheck.sh /usr/local/bin/healthcheck.sh
RUN chmod +x /usr/local/bin/healthcheck.sh

HEALTHCHECK --interval=30s --timeout=10s --start-period=1m --retries=3 CMD /usr/local/bin/healthcheck.sh

ENTRYPOINT ["/init"]
