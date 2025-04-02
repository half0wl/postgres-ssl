#!/bin/bash
set -e

SH_SSL="/usr/local/bin/_ssl.sh"
SH_PRIMARY="/usr/local/bin/_primary.sh"
SH_READREPLICA="/usr/local/bin/_readreplica.sh"

# ANSI colors
GREEN_R='\033[0;32m'
GREEN_B='\033[1;92m'
RED_R='\033[0;31m'
RED_B='\033[1;91m'
YELLOW_R='\033[0;33m'
YELLOW_B='\033[1;93m'
PURPLE_R='\033[0;35m'
PURPLE_B='\033[1;95m'
WHITE_R='\033[0;37m'
WHITE_B='\033[1;97m'
NC='\033[0m'

# Logging utils
log() {
  echo -e "[ ${WHITE_R}ℹ️ INFO${NC} ] ${WHITE_B}$1${NC}"
}

log_hl() {
  echo -e "[ ${PURPLE_R}ℹ️ INFO${NC} ] ${PURPLE_B}$1${NC}"
}

log_ok() {
  echo -e "[ ${GREEN_R}✅ OK${NC}   ] ${GREEN_B}$1${NC}"
}

log_warn() {
  echo -e "[ ${YELLOW_R}⚠️ WARN${NC} ] ${YELLOW_B}$1${NC}"
}

log_err() {
  echo -e "[ ${RED_R}⛔ ERR${NC}  ] ${RED_B}$1${NC}" >&2
}

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
        source "$SH_READREPLICA"
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
          source "$SH_PRIMARY"
      fi
      ;;
    *)
  esac
fi

source "$SH_SSL"
/usr/local/bin/docker-entrypoint.sh "$@"
