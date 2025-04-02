#!/bin/bash
set -e
source "/usr/local/bin/_include.sh"

if [ ! -z "$DEBUG_MODE" ]; then
  log "Starting in debug mode! Postgres will not run."
  log "The container will stay alive and be shell-accessible."
  trap "echo Shutting down; exit 0" SIGTERM SIGINT SIGKILL
  sleep infinity & wait
fi

# Ensure required environment variables are set
REQUIRED_ENV_VARS=(\
    "RAILWAY_VOLUME_NAME" \
    "RAILWAY_VOLUME_MOUNT_PATH" \
)
for var in "${REQUIRED_ENV_VARS[@]}"; do
    if [ -z "${!var}" ]; then
        log_err "Missing required environment variable: $var"
        exit 1
    fi
done

# PGDATA dir
PGDATA="${RAILWAY_VOLUME_MOUNT_PATH}/pgdata"
mkdir -p "$PGDATA"
sudo chown -R postgres:postgres "$PGDATA"
sudo chmod 700 "$PGDATA"

# Certs dir
SSL_CERTS_DIR="${RAILWAY_VOLUME_MOUNT_PATH}/certs"
mkdir -p "$SSL_CERTS_DIR"
sudo chown -R postgres:postgres "$SSL_CERTS_DIR"
sudo chmod 700 "$SSL_CERTS_DIR"

# Repmgr dir
REPMGR_DIR="${RAILWAY_VOLUME_MOUNT_PATH}/repmgr"
mkdir -p "$REPMGR_DIR"
sudo chown -R postgres:postgres "$REPMGR_DIR"
sudo chmod 700 "$REPMGR_DIR"

PG_CONF_FILE="${PGDATA}/postgresql.conf"
REPMGR_CONF_FILE="${REPMGR_DIR}/repmgr.conf"
ENSURE_SSL_SCRIPT="/usr/local/bin/ensure-ssl.sh"
CONFIGURE_PRIMARY_SCRIPT="/usr/local/bin/configure-primary.sh"
CONFIGURE_REPLICA_SCRIPT="/usr/local/bin/configure-replica.sh"
READ_REPLICA_MUTEX="${REPMGR_DIR}/rrmutex"

# Run different setup according to RAILWAY_PG_INSTANCE_TYPE
if [ -n "$RAILWAY_PG_INSTANCE_TYPE" ]; then
  case "$RAILWAY_PG_INSTANCE_TYPE" in
    "READREPLICA")
      # Configure as read replica
      if [ -f "$READ_REPLICA_MUTEX" ]; then
        log "Read replica appears to be configured. Skipping."
      else
        log_hl "Configuring as read replica"
        source "$CONFIGURE_REPLICA_SCRIPT"
      fi
      ;;
    "PRIMARY")
      # Configure as primary
      if grep -q \
        "include 'postgresql.replication.conf'" "$PG_CONF_FILE" 2>/dev/null;
          then
            log "Replication appears to be configured. Skipping."
      else
          log_hl "Configuring as primary"
          source "$CONFIGURE_PRIMARY_SCRIPT"
      fi
      ;;
    *)
  esac
fi

source "$ENSURE_SSL_SCRIPT"
/usr/local/bin/docker-entrypoint.sh "$@"
