#!/usr/bin/env bash
# Helpers shared by the on-instance deploy scripts (sourced, not executed).
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
export PATH="$PATH:/snap/bin"

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
  command -v aws >/dev/null 2>&1 || snap install aws-cli --classic
}

get_db_password() {
  ensure_awscli
  aws ssm get-parameter --region "$AWS_REGION" --name "$DB_PASSWORD_PARAM" \
    --with-decryption --query Parameter.Value --output text
}
