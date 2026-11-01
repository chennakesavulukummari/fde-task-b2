#!/usr/bin/env bash
# Runs ON the API EC2 instance (via SSM or user-data). Usage: api.sh <release_dir>
# Needs env: AWS_REGION, DB_PASSWORD_PARAM, DB_HOST, APP_VERSION
set -euo pipefail
RELEASE_DIR="${1:?release dir required}"
source "$RELEASE_DIR/deploy/common.sh"
DB_HOST="${DB_HOST:-127.0.0.1}"
[ "$DB_HOST" = "None" ] && DB_HOST="127.0.0.1"

APP_DIR=/opt/fde-task-app

wait_for_boot
apt_install python3-venv python3-pip unzip curl

id fdeapp >/dev/null 2>&1 || \
  useradd --system --home-dir "$APP_DIR" --shell /usr/sbin/nologin fdeapp

log "Copying API application code to $APP_DIR"
mkdir -p "$APP_DIR"
install -m 0644 "$RELEASE_DIR/api/app.py"           "$APP_DIR/app.py"
install -m 0644 "$RELEASE_DIR/api/requirements.txt" "$APP_DIR/requirements.txt"

log "Writing $APP_DIR/.env (DB_HOST=${DB_HOST})"
DB_PASSWORD="$(get_db_password)"
umask 077
cat > "$APP_DIR/.env" <<EOF
DB_HOST=${DB_HOST}
DB_PORT=3306
DB_NAME=fde_tasks
DB_USER=fde_app
DB_PASSWORD=${DB_PASSWORD}
APP_VERSION=${APP_VERSION:-1.0.0}
EOF
umask 022

log "Installing Python dependencies in virtualenv"
[ -x "$APP_DIR/.venv/bin/python" ] || python3 -m venv "$APP_DIR/.venv"
"$APP_DIR/.venv/bin/pip" install --quiet --upgrade pip
"$APP_DIR/.venv/bin/pip" install --quiet -r "$APP_DIR/requirements.txt" cryptography

chown -R fdeapp:fdeapp "$APP_DIR"
chmod 600 "$APP_DIR/.env"

log "Installing and starting systemd service fde-task-app"
install -m 0644 "$RELEASE_DIR/api/fde-task-app.service" /etc/systemd/system/fde-task-app.service
systemctl daemon-reload
systemctl enable fde-task-app
systemctl restart fde-task-app

log "Waiting for API health check on http://127.0.0.1:8000/api/health"
for i in $(seq 1 30); do
  if curl -fs http://127.0.0.1:8000/api/health; then
    echo
    log "API healthy"
    exit 0
  fi
  sleep 2
done

log "API failed health check. Service status and journal logs:"
systemctl status fde-task-app --no-pager || true
journalctl -u fde-task-app -n 60 --no-pager || true
exit 1
