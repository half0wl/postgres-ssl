#!/bin/bash
set -e

SH_CONFIGURE_SSL="/usr/local/bin/_configure_ssl.sh"
SH_CONFIGURE_PRIMARY="/usr/local/bin/_configure_primary.sh"
SH_CONFIGURE_READ_REPLICA="/usr/local/bin/_configure_read_replica.sh"

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

wait_for_postgres_start() {
  local sleep_time=3
  local max_attempts=10
  local attempt=1

  log "Waiting for Postgres to start ⏳"

  while [ $attempt -le $max_attempts ]; do
    log "Postgres is not ready. Re-trying in $sleep_time seconds (attempt $attempt/$max_attempts)"
    if psql $connection_string -c "SELECT 1;" >/dev/null 2>&1; then
      log_ok "Postgres is up and running!"
      return 0
    fi
    sleep $sleep_time
    attempt=$((attempt + 1))
  done

  log_err "Timed out waiting for Postgres to start! (exceeded $((max_attempts * sleep_time)) seconds)"
  return 1
}

wait_for_postgres_stop() {
  local sleep_time=3
  local max_attempts=10
  local attempt=1

  log "Waiting for Postgres to stop ⏳"

  while [ $attempt -le $max_attempts ]; do
    if ! pg_ctl -D "$PGDATA" status >/dev/null 2>&1; then
      return 0
    fi
    log "Postgres is still shutting down. Re-checking in $sleep_time seconds (attempt $attempt/$max_attempts)"
    sleep $sleep_time
    attempt=$((attempt + 1))
  done

  log_err "Timed out waiting for Postgres to stop! (exceeded $((max_attempts * sleep_time)) seconds)"
  return 1
}

echo ""
log_hl "Version: $RAILWAY_RELEASE_VERSION"
echo ""
log_warn "This is an ALPHA version of the Railway Postgres image."
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
    if ! [[ "$OUR_NODE_ID" =~ ^[0-9]+$ ]]; then
      log_err "OUR_NODE_ID is required in READREPLICA mode. It must be an integer ≥2."
      log_err "The primary node is always 'node1' and subsequent nodes must be numbered starting from 2."
      log_err "(received OUR_NODE_ID='$OUR_NODE_ID')"
      exit 1
    fi
    if [ "$OUR_NODE_ID" -lt 2 ]; then
      log_err "OUR_NODE_ID is required in READREPLICA mode. It must be an integer ≥2."
      log_err "The primary node is always 'node1' and subsequent nodes must be numbered starting from 2."
      log_err "(received OUR_NODE_ID='$OUR_NODE_ID')"
      exit 1
    fi
    log_hl "Running as READREPLICA (nodeid=$OUR_NODE_ID)"

    # Configure as read replica if not already done
    if [ -f "$READ_REPLICA_MUTEX" ]; then
      log "Skipping configuration for READREPLICA (appears to be configured already)"
    else
      source "$SH_CONFIGURE_READ_REPLICA"
    fi
    ;;
  "PRIMARY")
    log_hl "Running as PRIMARY (nodeid=1)"

    # Configure as primary if not already done
    if grep -q \
      "include 'postgresql.replication.conf'" "$PG_CONF_FILE" 2>/dev/null; then
      log "Skipping configuration for PRIMARY (appears to be configured already)"
    else
      source "$SH_CONFIGURE_PRIMARY"
    fi
    ;;
  *) ;;
  esac
fi

source "$SH_CONFIGURE_SSL"
/usr/local/bin/docker-entrypoint.sh "$@"
