#!/usr/bin/env bash
# Runs ON the API EC2 instance (via SSM). Usage: api.sh <release_dir>
# Needs env: AWS_REGION, DB_PASSWORD_PARAM, DB_HOST, APP_VERSION
set -euo pipefail
RELEASE_DIR="${1:?release dir required}"
source "$RELEASE_DIR/deploy/common.sh"
: "${DB_HOST:?DB_HOST required}"

APP_DIR=/opt/fde-task-app

wait_for_boot
apt_install python3-venv python3-pip curl

id fdeapp >/dev/null 2>&1 || \
  useradd --system --home-dir "$APP_DIR" --shell /usr/sbin/nologin fdeapp

log "Copying application code"
mkdir -p "$APP_DIR"
install -m 0644 "$RELEASE_DIR/api/app.py"          "$APP_DIR/app.py"
install -m 0644 "$RELEASE_DIR/api/requirements.txt" "$APP_DIR/requirements.txt"

log "Writing .env"
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
chown -R fdeapp:fdeapp "$APP_DIR"
chmod 600 "$APP_DIR/.env"

log "Installing Python dependencies"
[ -x "$APP_DIR/.venv/bin/python" ] || sudo -u fdeapp python3 -m venv "$APP_DIR/.venv"
sudo -u fdeapp "$APP_DIR/.venv/bin/pip" install --quiet --upgrade pip
sudo -u fdeapp "$APP_DIR/.venv/bin/pip" install --quiet -r "$APP_DIR/requirements.txt"

log "Installing systemd service"
install -m 0644 "$RELEASE_DIR/api/fde-task-app.service" /etc/systemd/system/fde-task-app.service
systemctl daemon-reload
systemctl enable fde-task-app
systemctl restart fde-task-app

log "Waiting for health check"
for i in $(seq 1 30); do
  if curl -fsS http://127.0.0.1:8000/api/health; then echo; log "API healthy"; exit 0; fi
  sleep 2
done
journalctl -u fde-task-app -n 60 --no-pager
log "API failed health check"; exit 1
