#!/bin/bash

log "🚀 Starting replica configuration..."

if [ "$RAILWAY_PG_INSTANCE_TYPE" != "READREPLICA" ]; then
    log_err "This script can only be executed on a replica instance."
    log_err "(expected: RAILWAY_PG_INSTANCE_TYPE='READREPLICA')"
    log_err "(received: RAILWAY_PG_INSTANCE_TYPE='$RAILWAY_PG_INSTANCE_TYPE')"
    exit 1
fi

if ! [[ "$OUR_NODE_ID" =~ ^[0-9]+$ ]]; then
  log_err "OUR_NODE_ID must be an integer."
  log_err "(received: OUR_NODE_ID='$OUR_NODE_ID')"
  exit 1
fi

if [ "$OUR_NODE_ID" -lt 2 ]; then
  log_err "OUR_NODE_ID must be ≥2. The primary node is always 'node1'"
  log_err "and subsequent nodes must be numbered starting from 2."
  log_err "(received: OUR_NODE_ID='$OUR_NODE_ID')"
  exit 1
fi

# Create repmgr configuration file
cat > "$REPMGR_CONF_FILE" << EOF
node_id=${OUR_NODE_ID}
node_name='node${OUR_NODE_ID}'
conninfo='host=${RAILWAY_PRIVATE_DOMAIN} port=${PGPORT} user=repmgr dbname=repmgr connect_timeout=10 sslmode=disable'
data_directory='${PG_DATA_DIR}'
EOF
log "Created repmgr configuration at '$REPMGR_CONF_FILE'"

# Start clone process in background
export PGPASSWORD="$PRIMARY_REPMGR_PWD" # for connecting to primary
su -m postgres -c \
   "repmgr -h $PRIMARY_PGHOST -p $PRIMARY_PGPORT \
   -d repmgr -U repmgr -f $REPMGR_CONF_FILE \
   standby clone --force 2>&1" &
repmgr_pid=$!
log "Performing clone of primary node. This may take awhile! ⏳"
while kill -0 $repmgr_pid 2>/dev/null; do
    # print progress indicator
    echo -n "."
    sleep 5
done
wait $repmgr_pid
repmgr_status=$?

if [ $repmgr_status -ne 0 ]; then
  log_err "Failed to clone primary node."
  exit 1
else
  log_ok "Successfully cloned primary node"
  log "Performing post-replication setup ⏳"
  # Start Postgres to register replica node
  source "$SH_SSL"
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
fi
