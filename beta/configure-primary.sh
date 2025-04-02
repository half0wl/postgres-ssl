#!/bin/bash
# --------------------------------------------------------------------------- #
# Configure and run a Postgres primary replica using repmgr.
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
    "RAILWAY_PRIVATE_DOMAIN" \
    "REPMGR_USER_PWD" \
    "PGPORT" \
    "PGDATA" \
)
for var in "${REQUIRED_ENV_VARS[@]}"; do
    if [ -z "${!var}" ]; then
        log_err "Missing required environment variable: $var"
        exit 1
    fi
done

# Set up required variables, directories, and files
REPMGR_DIR="${RAILWAY_VOLUME_MOUNT_PATH}/repmgr"
PG_CONF_FILE="${PGDATA}/postgresql.conf"
PG_REPLICATION_CONF_FILE="${PG_DATA_DIR}/postgresql.replication.conf"
PG_HBA_CONF_FILE="${PGDATA}/pg_hba.conf"

mkdir -p "$REPMGR_DIR"

# Set up permissions
sudo chown -R postgres:postgres "$REPMGR_DIR"
sudo chmod 700 "$REPMGR_DIR"

log_hl "RAILWAY_VOLUME_NAME         = $RAILWAY_VOLUME_NAME"
log_hl "RAILWAY_VOLUME_MOUNT_PATH   = $RAILWAY_VOLUME_MOUNT_PATH"
log_hl "RAILWAY_PRIVATE_DOMAIN      = $RAILWAY_PRIVATE_DOMAIN"
log_hl "REPMGR_USER_PWD             = $REPMGR_USER_PWD"
log_hl "PGPORT                      = $PGPORT"
log_hl "PGDATA                      = $PGDATA"
log_hl "REPMGR_DIR                  = $REPMGR_DIR"
log_hl "PG_CONF_FILE                = $PG_CONF_FILE"
log_hl "PG_REPLICATION_CONF_FILE    = $PG_REPLICATION_CONF_FILE"
log_hl "PG_HBA_CONF_FILE            = $PG_HBA_CONF_FILE"

if grep -q \
    "include 'postgresql.replication.conf'" "$PG_CONF_FILE" 2>/dev/null; then
        log "Primary configuration appears to be configured. Skipping."
    exit 1
fi

# Create replication configuration file
log "Creating replication configuration file at '$PG_REPLICATION_CONF_FILE'"
cat > "PG_REPLICATION_CONF_FILE" << EOF
max_wal_senders = 20
max_replication_slots = 20
wal_keep_segments = 800
wal_level = replica
wal_log_hints = on
hot_standby = on
archive_mode = on
archive_command = '/bin/true'
EOF

# Modify PG_CONF_FILE to include replication conf
PG_CONF_FILE_BAK="${PG_CONF_FILE}.$(date +'%d-%m-%Y').bak"
log "Backing up '$PG_CONF_FILE' to '$PG_CONF_FILE_BAK' ⏳"
cp $PG_CONF_FILE $PG_CONF_FILE_BAK
log_ok "'$PG_CONF_FILE' backed up to '$PG_CONF_FILE_BAK'"
echo "" >> "$PG_CONF_FILE"
echo "# Added by Railway replication setup on $(date +'%Y-%m-%d %H:%M:%S')" >> "$PG_CONF_FILE"
echo "include 'postgresql.replication.conf'" >> "$PG_CONF_FILE"
log_ok "Added include directive to '$PG_CONF_FILE'"

# Create repmgr user and database
log "Creating repmgr user and database ⏳"
if ! psql -c "SELECT 1 FROM pg_roles WHERE rolname='repmgr'" | grep -q 1; then
    psql -c "CREATE USER repmgr WITH SUPERUSER PASSWORD '${REPMGR_USER_PWD}';"
    log_ok "Created repmgr user"
else
    log "User repmgr already exists"
fi

if ! psql -c "SELECT 1 FROM pg_database WHERE datname='repmgr'" | grep -q 1; then
    psql -c "CREATE DATABASE repmgr;"
    log_ok "Created repmgr database"
else
    log "Database repmgr already exists"
fi

psql -c "GRANT ALL PRIVILEGES ON DATABASE repmgr TO repmgr;"
psql -c "ALTER USER repmgr SET search_path TO repmgr, railway, public;"
log_ok "Configured repmgr user and database permissions"

# Create repmgr configuration file
cat > "$REPMGR_CONF" << EOF
node_id=1
node_name='node1'
conninfo='host=${RAILWAY_PRIVATE_DOMAIN} port=${PGPORT} user=repmgr dbname=repmgr connect_timeout=10'
data_directory='${PGDATA}'
use_replication_slots=yes
monitoring_history=yes
EOF
log_ok "Created repmgr configuration at '$REPMGR_CONF'"

# Register primary node
log "Registering primary node with repmgr ⏳"
export PGPASSWORD="$REPMGR_USER_PASSWORD"
if su -m postgres -c "repmgr -f $REPMGR_CONF primary register"; then
    log_ok "Successfully registered primary node"
else
    log_err "Failed to register primary node with repmgr"
    exit 1
fi

# Modify pg_hba.conf to allow replication access

LAST_LINE=$(tail -n 1 "$PG_HBA_CONF")
if [ "$LAST_LINE" != "host all all all scram-sha-256" ]; then
    log_err "The last line of pg_hba.conf is not 'host all all all scram-sha-256'"
    log_err "Current last line: '$LAST_LINE'"
    log_err "Skipping pg_hba.conf modification"
else
    # Create backup
    PG_HBA_CONF_FILE_BAK="${PG_HBA_CONF_FILE}.$(date +'%d-%m-%Y').bak"
    log "Backing up '$PG_HBA_CONF_FILE' to '$PG_HBA_CONF_FILE_BAK' ⏳"
    cp $PG_HBA_CONF_FILE $PG_HBA_CONF_FILE_BAK
    log_ok "'$PG_HBA_CONF_FILE' backed up to '$PG_HBA_CONF_FILE_BAK'"

    # Create temporary file with the desired content
    _TMPFILE=$(mktemp)
    # Get all lines except the last one
    head -n -1 "$PG_HBA_CONF" > "$_TMPFILE"
    # Add our new line
    echo "# Added by Railway on $(date +'%Y-%m-%d %H:%M:%S')" >> "$_TMPFILE"
    echo "host replication repmgr ::0/0 trust" >> "$_TMPFILE"
    # Add the last line back
    echo "host all all all scram-sha-256" >> "$_TMPFILE"

    # Replace the original file
    mv "$_TMPFILE" "$PG_HBA_CONF"
    sudo chown postgres:postgres "$PG_HBA_CONF"
    sudo chmod 600 "$PG_HBA_CONF"

    log_ok "Successfully updated '$PG_HBA_CONF_FILE' with replication access."
fi

log_ok "Primary node configuration complete."
