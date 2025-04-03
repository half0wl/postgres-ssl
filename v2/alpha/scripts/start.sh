#!/bin/bash
set -e

SH_CONFIGURE_SSL="/usr/local/bin/_configure_ssl.sh"
SH_CONFIGURE_PRIMARY="/usr/local/bin/_configure_primary.sh"
SH_CONFIGURE_READ_REPLICA="/usr/local/bin/_configure_read_replica.sh"

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

echo ""
echo ""
echo "--------------------------------------------------------------------"
log_warn "This is an ALPHA version of the Railway Postgres image."
log_warn ""
log_warn "DO NOT USE THIS VERSION UNLESS ADVISED BY RAILWAY STAFF."
log_warn ""
log_warn "This version must only be used with direct support from"
log_warn "Railway. If we did not ask you to use this version,"
log_warn "please do not."
log_warn ""
log_warn "If you choose to use this version WITHOUT BEING ADVISED"
log_warn "OR ASKED TO by the Railway team:"
log_warn ""
log_warn "  You accept that you are doing so at your own risk,"
log_warn "  and Railway is not responsible for any data loss"
log_warn "  or corruption that may occur as a result of"
log_warn "  ignoring this warning."
echo "--------------------------------------------------------------------"
echo ""
echo ""

if [ ! -z "$DEBUG_MODE" ]; then
  log "Starting in debug mode! Postgres will not run."
  log "The container will stay alive and be shell-accessible."
  trap "echo Shutting down; exit 0" SIGTERM SIGINT SIGKILL
  sleep infinity &
  wait
fi

# Ensure required environment variables are set
REQUIRED_ENV_VARS=(
  "RAILWAY_VOLUME_NAME"
  "RAILWAY_VOLUME_MOUNT_PATH"
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
      source "$SH_CONFIGURE_READ_REPLICA"
    fi
    ;;
  "PRIMARY")
    # Configure as primary
    if grep -q \
      "include 'postgresql.replication.conf'" "$PG_CONF_FILE" 2>/dev/null; then
      log "Primary replication appears to be configured. Skipping."
    else
      source "$SH_CONFIGURE_PRIMARY"
    fi
    ;;
  *) ;;
  esac
fi

source "$SH_CONFIGURE_SSL"
/usr/local/bin/docker-entrypoint.sh "$@"
