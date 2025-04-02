#!/bin/bash
set -e
source "/usr/local/bin/_include.sh"

ENSURE_SSL_SCRIPT="/usr/local/bin/ensure-ssl.sh"
CONFIGURE_PRIMARY_SCRIPT="/usr/local/bin/configure-primary.sh"
CONFIGURE_REPLICA_SCRIPT="/usr/local/bin/configure-replica.sh"
PG_CONF_FILE="${PGDATA}/postgresql.conf"

# Check the RAILWAY_PG_INSTANCE_MODE environment variable
if [ -n "$RAILWAY_PG_INSTANCE_MODE" ]; then
  case "$RAILWAY_PG_INSTANCE_MODE" in
    "READREPLICA")
      # Configure as read replica
      source "$CONFIGURE_REPLICA_SCRIPT"
      ;;
    "PRIMARY")
      # Configure as primary
      source "$CONFIGURE_PRIMARY_SCRIPT"
      ;;
    *)
  esac
fi

# Continue with the normal startup process
source "$ENSURE_SSL_SCRIPT"
/usr/local/bin/docker-entrypoint.sh "$@"
