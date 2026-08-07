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
