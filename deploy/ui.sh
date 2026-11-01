#!/usr/bin/env bash
# Runs ON the UI EC2 instance (via SSM or user-data). Usage: ui.sh <release_dir>
# Needs env: API_HOST (private IP of the API instance), APP_VERSION
set -euo pipefail
RELEASE_DIR="${1:?release dir required}"
source "$RELEASE_DIR/deploy/common.sh"
API_HOST="${API_HOST:-127.0.0.1}"
[ "$API_HOST" = "None" ] && API_HOST="127.0.0.1"

WEB_ROOT=/var/www/fde-task-app

wait_for_boot
apt_install nginx unzip curl

log "Publishing UI static files to webserver document root ($WEB_ROOT)"
mkdir -p "$WEB_ROOT"
rm -rf "${WEB_ROOT:?}/"*
cp "$RELEASE_DIR/ui/index.html" "$RELEASE_DIR/ui/styles.css" "$RELEASE_DIR/ui/app.js" "$WEB_ROOT/"
echo "${APP_VERSION:-unknown}" > "$WEB_ROOT/version.txt"
chown -R www-data:www-data "$WEB_ROOT" || true
chmod -R a+rX "$WEB_ROOT"

log "Configuring Nginx -> API at ${API_HOST}:8000"
sed "s/__API_HOST__/${API_HOST}/g" "$RELEASE_DIR/ui/nginx.conf.tpl" \
  > /etc/nginx/sites-available/fde-task-app
ln -sf /etc/nginx/sites-available/fde-task-app /etc/nginx/sites-enabled/fde-task-app
rm -f /etc/nginx/sites-enabled/default

nginx -t
systemctl enable nginx
systemctl reload nginx || systemctl restart nginx

curl -fsS -o /dev/null http://127.0.0.1/ && log "UI webserver is serving on port 80"
if [ "$API_HOST" != "127.0.0.1" ]; then
  curl -fsS http://127.0.0.1/api/health && echo && log "UI -> API proxy OK" || \
    log "WARNING: API at ${API_HOST}:8000 is not reachable yet (deploy API/DB next)"
fi
