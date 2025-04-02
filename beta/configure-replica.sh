#!/bin/bash
# --------------------------------------------------------------------------- #
# Configure and run a Postgres read replica using repmgr.
#
# This script is intended to be run as the entrypoint for a container
# running Postgres on Railway. It is not intended to be run directly!
#
# https://docs.railway.com/tutorials/postgres-replication
# --------------------------------------------------------------------------- #
set -e
source _include.sh

# Ensure required environment variables are set
REQUIRED_ENV_VARS=(\
    "RAILWAY_VOLUME_NAME" \
    "RAILWAY_VOLUME_MOUNT_PATH" \
    "PRIMARY_PGHOST" \
    "PRIMARY_PGPORT" \
    "PRIMARY_REPMGR_PWD" \
    "OUR_NODE_ID" \
)
for var in "${REQUIRED_ENV_VARS[@]}"; do
    if [ -z "${!var}" ]; then
        log_err "Missing required environment variable: $var"
        exit 1
    fi
done

# Set up required variables, directories, and files
REPMGR_DIR="${RAILWAY_VOLUME_MOUNT_PATH}/repmgr"
PG_DATA_DIR="${RAILWAY_VOLUME_MOUNT_PATH}/pgdata"
PG_LOGS_DIR="${RAILWAY_VOLUME_MOUNT_PATH}/pglogs"
SSL_CERTS_DIR="${RAILWAY_VOLUME_MOUNT_PATH}/certs"

mkdir -p "$REPMGR_DIR"
mkdir -p "$PG_DATA_DIR"
mkdir -p "$PG_LOGS_DIR"
mkdir -p "$SSL_CERTS_DIR"

REPLICATION_MUTEX="${REPMGR_DIR}/mutex"
REPMGR_CONF_FILE="${REPMGR_DIR}/repmgr.conf"
PG_CONF_FILE="${PG_DATA_DIR}/postgresql.conf"
PG_LOG_FILE="${PG_LOGS_DIR}/1.json"
PG_EXTRA_OPTS="${PG_EXTRA_OPTS}"
ENSURE_SSL_SCRIPT="ensure-ssl.sh"

# Set up permissions
sudo chown -R postgres:postgres "$REPMGR_DIR"
sudo chown -R postgres:postgres "$PG_DATA_DIR"
sudo chown -R postgres:postgres "$PG_LOGS_DIR"
sudo chown -R postgres:postgres "$SSL_CERTS_DIR"
sudo chmod 700 "$PG_DATA_DIR"
sudo chmod 700 "$PG_LOGS_DIR"
sudo chmod 700 "$REPMGR_DIR"

log_hl "RAILWAY_VOLUME_NAME         = $RAILWAY_VOLUME_NAME"
log_hl "RAILWAY_VOLUME_MOUNT_PATH   = $RAILWAY_VOLUME_MOUNT_PATH"
log_hl "PRIMARY_PGHOST              = $PRIMARY_PGHOST"
log_hl "PRIMARY_PGPORT              = $PRIMARY_PGPORT"
log_hl "PRIMARY_REPMGR_PWD          = ***${PRIMARY_REPMGR_PWD: -4}"
log_hl "OUR_NODE_ID                 = $OUR_NODE_ID"
log_hl "REPMGR_DIR                  = $REPMGR_DIR"
log_hl "REPMGR_CONF_FILE            = $REPMGR_CONF_FILE"
log_hl "PG_DATA_DIR                 = $PG_DATA_DIR"
log_hl "PG_CONF_FILE                = $PG_CONF_FILE"
log_hl "PG_EXTRA_OPTS               = $PG_EXTRA_OPTS"
log_hl "PG_LOGS_DIR                 = $PG_LOGS_DIR"
log_hl "PG_LOG_FILE                 = $PG_LOG_FILE"
log_hl "SSL_CERTS_DIR               = $SSL_CERTS_DIR"

if [ ! -z "$DEBUG_MODE" ]; then
  log "Starting in debug mode! Postgres will not run."
  log "The container will stay alive and be shell-accessible."
  trap "echo Shutting down; exit 0" SIGTERM SIGINT SIGKILL
  sleep infinity & wait
fi

# Allow passing additional Postgres options through $PG_EXTRA_OPTS env var
if [ -n "$PG_EXTRA_OPTS" ]; then
  set -- "$@" $PG_EXTRA_OPTS
fi

# OUR_NODE_ID must be numeric, and ≥2
if ! [[ "$OUR_NODE_ID" =~ ^[0-9]+$ ]]; then
  log_err "OUR_NODE_ID must be an integer."
  exit 1
fi
if [ "$OUR_NODE_ID" -lt 2 ]; then
  log_err "OUR_NODE_ID must be ≥2. The primary node is always 'node1'"
  log_err "and subsequent nodes must be numbered starting from 2."
  exit 1
fi

if [ ! -f "$REPLICATION_MUTEX" ]; then
    log "🚀 Starting replication setup..."

    cat > "$REPMGR_CONF_FILE" << EOF
node_id=${OUR_NODE_ID}
node_name='node${OUR_NODE_ID}'
conninfo='host=${PGHOST} port=${PGPORT} user=repmgr dbname=repmgr connect_timeout=10 sslmode=disable'
data_directory='${PG_DATA_DIR}'
EOF
    log "Created repmgr configuration at '$REPMGR_CONF_FILE'"

    # Start clone process in background so we can output progress
    export PGPASSWORD="$PRIMARY_REPMGR_PWD" # for connecting to primary
    su -m postgres -c \
       "repmgr -h $PRIMARY_PGHOST -p $PRIMARY_PGPORT \
       -d repmgr -U repmgr -f $REPMGR_CONF_FILE \
       standby clone --force 2>&1" &
    repmgr_pid=$!

    log "Performing clone of primary node. This may take awhile! ⏳"
    while kill -0 $repmgr_pid 2>/dev/null; do
        echo -n "."
        sleep 5
    done

    wait $repmgr_pid
    repmgr_status=$?

    if [ $repmgr_status -eq 0 ]; then
      log_ok "Successfully cloned primary node"

      log "Performing post-replication setup ⏳"
      # Start Postgres to register replica node
      source "$ENSURE_SSL_SCRIPT"
      su -m postgres -c "pg_ctl -D ${PG_DATA_DIR} start"
      if su -m postgres -c \
          "repmgr standby register --force -f $REPMGR_CONF_FILE 2>&1"
      then
          log_ok "Successfully registered replica node."
          # Stop Postgres after registration; we'll let the image entrypoint
          # start Postgres after
          su -m postgres -c "pg_ctl -D ${PG_DATA_DIR} stop"
          # Acquire mutex to indicate replication setup is complete; this is
          # just a file that we create - its presence indicates that the
          # replication setup has been completed and should not be run again
          touch "$REPLICATION_MUTEX"
      else
          log_err "Failed to register replica node."
          su -m postgres -c "pg_ctl -D ${PG_DATA_DIR} stop"
          exit 1
      fi
    else
      log_err "Failed to clone primary node"
      exit 1
    fi
else
    log_ok "Replication setup already completed. Starting Postgres."
fi

# Run Postgres via the image's entrypoint script
# source "$ENSURE_SSL_SCRIPT"
# /usr/local/bin/docker-entrypoint.sh "$@"
