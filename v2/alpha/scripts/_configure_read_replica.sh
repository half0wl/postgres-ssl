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

if [ -z "$PRIMARY_REPMGR_USER_PWD" ]; then
  log_err "PRIMARY_REPMGR_USER_PWD is required for read replica configuration."
  exit 1
fi

# Store the current value of PGPASSWORD; we need to export this to the primary
# repmgr user password for repmgr to pick it up, and we also need this value
# subsequently to start Postgres for replica registration
CURRENT_PGPASSWORD="$PGPASSWORD"

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
export PGPASSWORD="$PRIMARY_REPMGR_USER_PWD" # for connecting to primary
su -m postgres -c \
  "repmgr -h $PRIMARY_PGHOST -p $PRIMARY_PGPORT \
   -d repmgr -U repmgr -f $REPMGR_CONF_FILE \
   standby clone --force 2>&1" &
repmgr_pid=$!

log_ok "Performing clone of primary node. This may take awhile! ⏳"
while kill -0 $repmgr_pid 2>/dev/null; do
  echo -n "." # print progress indicator
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

# source "$SH_CONFIGURE_SSL"
# export PGPASSWORD="$CURRENT_PGPASSWORD" # restore original PGPASSWORD
# try_start_postgres

if su -m postgres -c \
  "repmgr -h $PRIMARY_PGHOST -p $PRIMARY_PGPORT \
   -d repmgr -U repmgr -f $REPMGR_CONF_FILE \
   standby register --force 2>&1"; then
  log_ok "Successfully registered replica node."
  # Acquire mutex to indicate replication setup is complete; this is
  # just a file that we create - its presence indicates that the
  # replication setup has been completed and should not be run again
  touch "$READ_REPLICA_MUTEX"
else
  log_err "Failed to register replica node."
fi

# try_stop_postgres
