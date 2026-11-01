#!/usr/bin/env bash
# Runs ON the DB EC2 instance (via SSM or user-data). Usage: db.sh <release_dir>
# Needs env: AWS_REGION, DB_PASSWORD_PARAM, APP_VERSION
set -euo pipefail
RELEASE_DIR="${1:?release dir required}"
source "$RELEASE_DIR/deploy/common.sh"

wait_for_boot
apt_install mysql-server unzip curl

log "Configuring MySQL to listen on 0.0.0.0:3306 (private VPC network)"
if [ -f /etc/mysql/mysql.conf.d/mysqld.cnf ]; then
  sed -i 's/^[[:space:]]*bind-address.*/bind-address = 0.0.0.0/' /etc/mysql/mysql.conf.d/mysqld.cnf
fi
cat > /etc/mysql/mysql.conf.d/99-fde.cnf <<'EOF'
[mysqld]
bind-address        = 0.0.0.0
mysqlx-bind-address = 127.0.0.1
EOF
systemctl enable mysql
systemctl restart mysql

for i in $(seq 1 30); do mysqladmin ping >/dev/null 2>&1 && break; sleep 2; done
ss -tlnp | grep 3306 || true

log "Applying schema from db/init.sql"
mysql < "$RELEASE_DIR/db/init.sql"

log "Creating/rotating application user fde_app"
DB_PASSWORD="$(get_db_password)"
# Network access to 3306 is restricted to the API security group.
mysql <<SQL
CREATE USER IF NOT EXISTS 'fde_app'@'%' IDENTIFIED BY '${DB_PASSWORD}';
ALTER USER 'fde_app'@'%' IDENTIFIED BY '${DB_PASSWORD}';
GRANT SELECT, INSERT, UPDATE, DELETE, CREATE ON fde_tasks.* TO 'fde_app'@'%';
FLUSH PRIVILEGES;
SQL

echo "${APP_VERSION:-unknown}" > /etc/mysql/fde-release
log "DB deployed. Tables:"
mysql -N -e "SHOW TABLES FROM fde_tasks;"
