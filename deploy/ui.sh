#!/usr/bin/env bash
# Runs ON the UI EC2 instance (via SSM). Usage: ui.sh <release_dir>
# Needs env: API_HOST (private IP of the API instance), APP_VERSION
set -euo pipefail
RELEASE_DIR="${1:?release dir required}"
source "$RELEASE_DIR/deploy/common.sh"
: "${API_HOST:?API_HOST required}"

WEB_ROOT=/var/www/fde-task-app

wait_for_boot
apt_install nginx curl

log "Publishing static files"
mkdir -p "$WEB_ROOT"
rm -rf "${WEB_ROOT:?}/"*
cp "$RELEASE_DIR/ui/index.html" "$RELEASE_DIR/ui/styles.css" "$RELEASE_DIR/ui/app.js" "$WEB_ROOT/"
echo "${APP_VERSION:-unknown}" > "$WEB_ROOT/version.txt"
chmod -R a+rX "$WEB_ROOT"

log "Configuring Nginx -> API at ${API_HOST}:8000"
sed "s/__API_HOST__/${API_HOST}/g" "$RELEASE_DIR/ui/nginx.conf.tpl" \
  > /etc/nginx/sites-available/fde-task-app
ln -sf /etc/nginx/sites-available/fde-task-app /etc/nginx/sites-enabled/fde-task-app
rm -f /etc/nginx/sites-enabled/default

nginx -t
systemctl enable nginx
systemctl reload nginx || systemctl restart nginx

curl -fsS -o /dev/null http://127.0.0.1/ && log "UI is serving"
curl -fsS http://127.0.0.1/api/health && echo && log "UI -> API proxy OK"
