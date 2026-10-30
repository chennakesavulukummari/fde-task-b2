#!/usr/bin/env bash
# Runs ON the DB EC2 instance (via SSM). Usage: db.sh <release_dir>
# Needs env: AWS_REGION, DB_PASSWORD_PARAM, APP_VERSION
set -euo pipefail
RELEASE_DIR="${1:?release dir required}"
source "$RELEASE_DIR/deploy/common.sh"

wait_for_boot
apt_install mysql-server

log "Configuring MySQL to listen on the private network"
cat > /etc/mysql/mysql.conf.d/99-fde.cnf <<'EOF'
[mysqld]
bind-address        = 0.0.0.0
mysqlx-bind-address = 127.0.0.1
EOF
systemctl enable mysql
systemctl restart mysql

for i in $(seq 1 30); do mysqladmin ping >/dev/null 2>&1 && break; sleep 2; done

log "Applying schema"
mysql < "$RELEASE_DIR/db/init.sql"

log "Creating/rotating application user"
DB_PASSWORD="$(get_db_password)"
# Password is generated alphanumeric by bootstrap/setup.sh, so it is safe in quotes.
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
