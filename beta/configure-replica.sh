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
    "RAILWAY_PG_INSTANCE_TYPE" \
    "RAILWAY_VOLUME_NAME" \
    "RAILWAY_VOLUME_MOUNT_PATH" \
    "RAILWAY_PRIVATE_DOMAIN" \
    "PGDATA" \
    "PGPORT" \
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

if [ "$RAILWAY_PG_INSTANCE_TYPE" != "READREPLICA" ]; then
    log_err "This script is intended to be run for read replicas only."
    exit 1
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

log "🚀 Starting replication setup..."

cat > "$REPMGR_CONF_FILE" << EOF
node_id=${OUR_NODE_ID}
node_name='node${OUR_NODE_ID}'
conninfo='host=${RAILWAY_PRIVATE_DOMAIN} port=${PGPORT} user=repmgr dbname=repmgr connect_timeout=10 sslmode=disable'
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
  log_err "Failed to clone primary node."
  exit 1
fi
