#!/usr/bin/env bash
# Helpers shared by the on-instance deploy scripts (sourced, not executed).
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
export PATH="$PATH:/snap/bin:/usr/local/bin"

log() { echo "[$(date -u +%H:%M:%S)] $*"; }

# Wait for first-boot cloud-init (user-data apt installs) to finish.
wait_for_boot() {
  if command -v cloud-init >/dev/null 2>&1; then
    cloud-init status --wait >/dev/null 2>&1 || true
  fi
}

apt_install() {
  local missing=()
  for p in "$@"; do dpkg -s "$p" >/dev/null 2>&1 || missing+=("$p"); done
  if [ "${#missing[@]}" -gt 0 ]; then
    log "Installing: ${missing[*]}"
    apt-get -o DPkg::Lock::Timeout=300 update -y
    apt-get -o DPkg::Lock::Timeout=300 install -y "${missing[@]}"
  fi
}

ensure_awscli() {
  while snap changes 2>/dev/null | grep -q 'Doing'; do sleep 2; done
  if ! command -v aws >/dev/null 2>&1; then
    snap install aws-cli --classic || {
      apt_install unzip curl
      curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
      unzip -q -o /tmp/awscliv2.zip -d /tmp
      /tmp/aws/install --update
    }
  fi
}

get_db_password() {
  ensure_awscli
  aws ssm get-parameter --region "${AWS_REGION:-ap-south-2}" --name "${DB_PASSWORD_PARAM:-/fde-task-app/db-password}" \
    --with-decryption --query Parameter.Value --output text 2>/dev/null || echo "${DB_PASSWORD:-FdeTaskPass123456}"
}
