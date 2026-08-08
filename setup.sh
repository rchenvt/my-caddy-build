#!/bin/sh
# setup.sh - Generates the All-In-One Auth Stack (Caddy, Authelia, LLDAP, Inbucket)

set -e
rm -rf s6-overlay Dockerfile healthcheck.sh docker-compose.yml

# 1. Create Folder Structure
gen-s6-folders() {
    echo "Building clean s6-overlay service framework..."
    
    # 1. Initialize user bundle auto-start directory
    mkdir -p s6-overlay/user-bundles.d/user/contents.d

    # 2. Build global init-permissions framework
    mkdir -p s6-overlay/s6-rc.d/init-permissions/dependencies.d
    echo "oneshot" > s6-overlay/s6-rc.d/init-permissions/type

    # 3. Loop through apps to create types and dependency nodes
    for app in caddy authelia lldap inbucket filebrowser; do
        mkdir -p "s6-overlay/s6-rc.d/$app/dependencies.d"
        mkdir -p "s6-overlay/s6-rc.d/init-$app/dependencies.d"

        # Define s6 service categories
        echo "longrun" > "s6-overlay/s6-rc.d/$app/type"
        echo "oneshot" > "s6-overlay/s6-rc.d/init-$app/type"

        # Internal dependency chain: app -> its init script -> global permissions
        touch "s6-overlay/s6-rc.d/$app/dependencies.d/init-$app"
        touch "s6-overlay/s6-rc.d/init-$app/dependencies.d/init-permissions"

        # Register only the main app to auto-start (s6-rc will pull dependencies)
        touch "s6-overlay/user-bundles.d/user/contents.d/$app"
    done

    # 4. Inter-app service stack definitions
    touch s6-overlay/s6-rc.d/inbucket/dependencies.d/caddy
    touch s6-overlay/s6-rc.d/lldap/dependencies.d/inbucket
    touch s6-overlay/s6-rc.d/authelia/dependencies.d/lldap
    touch s6-overlay/s6-rc.d/filebrowser/dependencies.d/authelia
    
    echo "Framework directory tree complete."
}

# ---------------------------------------------------------
# 2. Generate Init (Oneshot) Scripts
# ---------------------------------------------------------
gen-oneshot() {
    echo "Generating oneshot init scripts..."
    for app in caddy authelia lldap inbucket filebrowser permissions; do
        echo "/etc/s6-overlay/s6-rc.d/init-$app/run" > s6-rc.d/init-$app/up
    done

    # Init-permissions: update appuser:appuser to PUID:PGID if exist at container runtime
    cat << 'EOF' > s6-overlay/s6-rc.d/init-permissions/run
#!/command/with-contenv sh
# Dynamically remap the placeholder user to the runtime PUID/PGID

# Update Group GID
if [ ! -z "$PGID" ] && [ "$(id -g appuser)" != "$PGID" ]; then
    echo "[init-permissions] Remapping appuser to GID $PGID"
    sed -i "s/^appuser:x:[0-9]*:/appuser:x:$PGID:/" /etc/group
fi

# Update User UID
if [ ! -z "$PUID" ] && [ "$(id -u appuser)" != "$PUID" ]; then
    echo "[init-permissions] Remapping appuser to UID $PUID"
    sed -i "s/^appuser:x:[0-9]*:[0-9]*:/appuser:x:$PUID:$PGID:/" /etc/passwd
fi

chown -R appuser:appuser /data /config /srv
EOF

    # Init Authelia: Deconstructed from official entrypoint
    cat << 'EOF' > s6-overlay/s6-rc.d/init-authelia/run
#!/command/with-contenv sh
echo "[init-authelia] Setting up permissions..."
mkdir -p /config/authelia
if [ ! -f "/config/authelia/configuration.yml" ]; then
    touch /config/authelia/configuration.yml
fi
chown -R appuser:appuser /config/authelia
EOF

    # Init LLDAP: Deconstructed from official entrypoint
    cat << 'EOF' > s6-overlay/s6-rc.d/init-lldap/run
#!/command/with-contenv sh
echo "[init-lldap] Preparing LLDAP env..."
mkdir -p /data/lldap

if [ ! -f "/data/lldap/lldap_config.toml" ]; then
    cp -a /app/lldap_config.docker_template.toml /data/lldap/lldap_config.toml
fi
chown -R appuser:appuser /app /data/lldap
EOF

    # Init Inbucket: Deconstructed from start-inbucket.sh
    cat << 'EOF' > s6-overlay/s6-rc.d/init-inbucket/run
#!/command/with-contenv sh
echo "[init-inbucket] Setting up mail storage..."
mkdir -p /config/inbucket /data/inbucket
if [ ! -f "/config/inbucket/greeting.html" ]; then
    cp -a /opt/inbucket/defaults/greeting.html /config/inbucket/greeting.html
fi
chown -R appuser:appuser /config/inbucket /data/inbucket
EOF

    # Init Caddy
    cat << 'EOF' > s6-overlay/s6-rc.d/init-caddy/run
#!/command/with-contenv sh
echo "[init-caddy] Preparing Caddy folders..."
mkdir -p /etc/caddy /data/caddy /config/caddy /var/log/caddy
if [ ! -f /var/log/caddy/caddy.log ]; then
    touch /var/log/caddy/caddy.log
fi
if [ ! -f /var/log/caddy/access.log ]; then
    touch /var/log/caddy/access.log
fi
chown -R appuser:appuser /data/caddy /config/caddy /var/log/caddy
EOF

    # Init filebrowser
    cat << 'EOF' > s6-overlay/s6-rc.d/init-filebrowser/run
#!/command/with-contenv sh
echo "[init-filebrowser] Setting Up Config Files..."
mkdir -p /config/filebrowser /data/filebrowser /srv
if [ ! -f "/config/filebrowser/settings.json" ]; then
    cp -a /defaults/settings.json /config/filebrowser/settings.json
fi
chown -R appuser:appuser /config/filebrowser /data/filebrowser /srv
EOF

    # Ensure all newly created init run scripts are strictly executable
    chmod +x s6-overlay/s6-rc.d/*/run 2>/dev/null || true
    echo "Oneshot generation complete."
}
# ---------------------------------------------------------
# 3. Generate Service (Longrun) Run Scripts
# ---------------------------------------------------------
gen-longrun() {
    # Authelia
    cat << 'EOF' > s6-overlay/s6-rc.d/authelia/run
#!/command/with-contenv sh

echo "[authelia] Waiting for LLDAP to be ready on localhost:3890..."
# Loop until port 3890 is responsive
while ! nc -z 127.0.0.1 3890 || ! nc -z 127.0.0.1 2500; do   
  sleep 1
done

echo "[authelia] LLDAP and INBUCKET are up, starting Authelia..."
exec s6-setuidgid appuser authelia --config /config/authelia/configuration.yml
EOF
    # Caddy
    cat << 'EOF' > s6-overlay/s6-rc.d/caddy/run
#!/command/with-contenv sh
exec s6-setuidgid appuser caddy run --config /config/caddy/Caddyfile --adapter caddyfile
EOF
    # Inbucket
    cat << 'EOF' > s6-overlay/s6-rc.d/inbucket/run
#!/command/with-contenv sh
exec s6-setuidgid appuser inbucket -logjson
EOF
    # Lldap
    cat << 'EOF' > s6-overlay/s6-rc.d/lldap/run
#!/command/with-contenv sh
cd /app
exec s6-setuidgid appuser lldap run --config-file /data/lldap/lldap_config.toml
EOF
    # Filebrowser
    cat << 'EOF' > s6-overlay/s6-rc.d/filebrowser/run
#!/command/with-contenv sh
exec s6-setuidgid appuser filebrowser -c /config/filebrowser/settings.json
EOF
    # Ensure all scripts are executable
    chmod +x s6-overlay/s6-rc.d/*/run 2>/dev/null || true
}
# ---------------------------------------------------------
# 4. Generate the Consolidated Dockerfile
# ---------------------------------------------------------
gen-dockerfile() {
    cat <<'EOF' > Dockerfile
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

RUN apk add --no-cache tzdata && rm -f /var/log/apk.log

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

COPY s6-overlay/ /etc/s6-overlay/
RUN chmod +x /etc/s6-overlay/s6-rc.d/*/run

COPY healthcheck.sh /usr/local/bin/healthcheck.sh
RUN chmod +x /usr/local/bin/healthcheck.sh

HEALTHCHECK --interval=30s --timeout=10s --start-period=1m --retries=3 CMD /usr/local/bin/healthcheck.sh

ENTRYPOINT ["/init"]
EOF
}
# ---------------------------------------------------------
# 5. Generate Healthecheck.sh
# ---------------------------------------------------------
gen-healthcheck() {
    cat <<'EOF' > healthcheck.sh
#!/bin/sh
# Authelia API Check
wget -q --spider http://localhost:9091/api/health || exit 1
# LLDAP Binary Check
lldap healthcheck --config-file /data/lldap/lldap_config.toml > /dev/null || exit 1
# Inbucket Port Check
wget -q --spider http://localhost:9000 || exit 1
# Caddy Port Check
wget -q --spider http://localhost:2019/metrics || exit 1
# Filebrowser api
wget -q --spider http://localhost:8001/health || exit 1
EOF
    chmod +x healthcheck.sh
}
# ---------------------------------------------------------
# 6. Generate Docker Compose
# ---------------------------------------------------------
gen-compose() {
    cat << 'EOF' > docker-compose.yml
services:
  caddy:
#    build:
#      context: .
#      args:
#        - S6_ARCH=${S6_ARCH:-x86_64}
#        - S6_VER=${S6_VER:-3.2.2.0}
#        - CADDY=${CADDY:-caddy:alpine}
    image: ghcr:rchenvt/caddy
    container_name: caddy
    ports:
      - "80:80"
      - "443:443"
      - "443:443/udp"
    volumes:
      - ./read/Caddyfile:/etc/caddy/Caddyfile
      - ./log/caddy:/var/log/caddy
      - ./read/lldap_config.toml:/data/lldap/lldap_config.toml
      - ./read/configuration.yml:/config/authelia/configuration.yml
      - ./config:/config
      - ./data:/data
    environment:
      - DOMAINNAME=${DOMAINNAME}
      - TZ=$TZ
      # Caddy
#      - CLOUDFLARE_API_TOKEN=${CLOUDFLARE_API_TOKEN}
#      - CROWDSEC_API_KEY=${CROWDSEC_API_KEY}
      # Lldap
      - LLDAP_LDAP_BASE_DN=$LLDAP_LDAP_BASE_DN
      - LLDAP_LDAP_USER_DN=$LLDAP_LDAP_USER_DN
      - LLDAP_LDAP_USER_PASS=$LLDAP_LDAP_USER_PASS
      # Silent lldap session logs
      - RUST_LOG=lldap=warn,warp=warn,hyper=warn,sqlx=warn
      # Authelia
      - AUTHELIA_AUTHENTICATION_BACKEND_LDAP_PASSWORD=$LLDAP_LDAP_USER_PASS
      - AUTHELIA_AUTHENTICATION_BACKEND_LDAP_BASE_DN=$LLDAP_LDAP_BASE_DN
      - AUTHELIA_AUTHENTICATION_BACKEND_LDAP_USER=uid=${LLDAP_LDAP_USER_DN},ou=people,${LLDAP_LDAP_BASE_DN}
#      - X_AUTHELIA_CONFIG_FILTERS=template
      # Inbucket
      - INBUCKET_LOGLEVEL=error
      # Filebrowser
      - FB_NOAUTH=true
      - 
    restart: unless-stopped
#    networks:
#      - caddy
EOF
}

gen-s6-folders
gen-oneshot
gen-longrun
gen-healthcheck
gen-dockerfile
gen-compose

echo "Done! Run 'docker compose build' to create your image."
