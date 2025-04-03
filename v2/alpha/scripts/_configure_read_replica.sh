#!/bin/bash

log "Starting read replica configuration"

if [ "$RAILWAY_PG_INSTANCE_TYPE" != "READREPLICA" ]; then
  log_err "This script can only be executed on a replica instance."
  log_err "(expected: RAILWAY_PG_INSTANCE_TYPE='READREPLICA')"
  log_err "(received: RAILWAY_PG_INSTANCE_TYPE='$RAILWAY_PG_INSTANCE_TYPE')"
  exit 1
fi

if [ -z "$PRIMARY_PGHOST" ]; then
  log_err "PRIMARY_PGHOST is required for read replica configuration."
  exit 1
fi

if [ -z "$PRIMARY_PGPORT" ]; then
  log_err "PRIMARY_PGPORT is required for read replica configuration."
  exit 1
fi

# Create repmgr configuration file
cat >"$REPMGR_CONF_FILE" <<EOF
node_id=${OUR_NODE_ID}
node_name='node${OUR_NODE_ID}'
conninfo='host=${RAILWAY_PRIVATE_DOMAIN} port=${PGPORT} user=repmgr dbname=repmgr connect_timeout=10 sslmode=disable'
data_directory='${PGDATA}'
EOF
sudo chown postgres:postgres "$REPMGR_CONF_FILE"
sudo chmod 700 "$REPMGR_CONF_FILE"
log_ok "Created repmgr config ->> '$REPMGR_CONF_FILE'"

# Start clone process in background
export PGPASSWORD="$PRIMARY_REPMGR_PWD" # for connecting to primary
su -m postgres -c \
  "repmgr -h $PRIMARY_PGHOST -p $PRIMARY_PGPORT \
   -d repmgr -U repmgr -f $REPMGR_CONF_FILE \
   standby clone --force 2>&1" &
repmgr_pid=$!
log_ok "Performing clone of primary node. This may take awhile! ⏳"
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
  log_ok "Successfully cloned primary node."
fi

log "Performing post-replication setup ⏳"

# Start Postgres if not already running; this is needed to register the
# replica node
source "$SH_CONFIGURE_SSL"
if pg_ctl -D "$PGDATA" status >/dev/null 2>&1; then
  log_ok "Postgres is up and running!"
else
  log "Starting Postgres ⏳"
  su -m postgres -c "pg_ctl -D ${PGDATA} start"

  # Wait for Postgres to be ready after starting
  wait_for_postgres_start || {
    log_err "Failed to start Postgres properly. Exiting."
    exit 1
  }
fi

if su -m postgres -c \
  "repmgr standby register --force -f $REPMGR_CONF_FILE 2>&1"; then
  log_ok "Successfully registered replica node."
  # Stop Postgres after registration; we'll let the image entrypoint
  # start Postgres after
  su -m postgres -c "pg_ctl -D ${PG_DATA_DIR} stop"
  # Acquire mutex to indicate replication setup is complete; this is
  # just a file that we create - its presence indicates that the
  # replication setup has been completed and should not be run again
  touch "$READ_REPLICA_MUTEX"
else
  log_err "Failed to register replica node."
  su -m postgres -c "pg_ctl -D ${PG_DATA_DIR} stop"
  exit 1
fi

log_hl "Stopping Postgres ⏳"
su -m postgres -c "pg_ctl -D ${PGDATA} stop -m fast"

# Wait for Postgres to fully stop
wait_for_postgres_stop || {
  log_err "Postgres did not stop cleanly. Manual intervention may be required."
  # Force stop as a last resort if needed
  log_warn "Attempting to force stop Postgres."
  su -m postgres -c "pg_ctl -D ${PGDATA} stop -m immediate" || true
  sleep 3
}

# Verify Postgres has stopped
if pg_ctl -D "$PGDATA" status >/dev/null 2>&1; then
  log_warn "Postgres is still running despite stop attempts."
else
  log_ok "Postgres stopped. It will be restarted from the default entrypoint."
fi
