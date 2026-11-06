#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$REPO_ROOT/config.env"
: "${ARTIFACT_BUCKET:?ARTIFACT_BUCKET required}"

COMMIT_HASH="$(echo "${CODEBUILD_RESOLVED_SOURCE_VERSION:-local}" | cut -c 1-7)"
RELEASE_VERSION="${RELEASE_VERSION:-$(date -u +%Y%m%d-%H%M%S)-${COMMIT_HASH}}"
[[ "$RELEASE_VERSION" =~ ^[A-Za-z0-9._-]+$ ]] || {
  echo "Invalid release version: $RELEASE_VERSION" >&2
  exit 1
}
export IMAGE_TAG="$RELEASE_VERSION"

docker info >/dev/null
node --check "$REPO_ROOT/ui/app.js"
grep -q 'proxy_pass http://api:8000;' "$REPO_ROOT/ui/default.conf"
DB_PASSWORD=build-validation-password \
DB_ROOT_PASSWORD=build-validation-root-password \
docker compose --project-directory "$REPO_ROOT" config --quiet

echo "Building release $RELEASE_VERSION"
docker build --pull -t "fde-task-api:$RELEASE_VERSION" "$REPO_ROOT/api"
docker build --pull -t "fde-task-ui:$RELEASE_VERSION" "$REPO_ROOT/ui"
docker pull mysql:8.0

DIST_DIR="$REPO_ROOT/dist/docker"
mkdir -p "$DIST_DIR/db"
docker save \
  "fde-task-api:$RELEASE_VERSION" \
  "fde-task-ui:$RELEASE_VERSION" \
  mysql:8.0 | gzip -c > "$DIST_DIR/images.tar.gz"
cp "$REPO_ROOT/compose.yaml" "$DIST_DIR/compose.yaml"
cp "$REPO_ROOT/db/init.sql" "$DIST_DIR/db/init.sql"
(cd "$DIST_DIR" && sha256sum images.tar.gz > SHA256SUMS)
printf '{"component":"docker-stack","version":"%s","commit":"%s","built_at":"%s"}\n' \
  "$RELEASE_VERSION" "$COMMIT_HASH" "$(date -u +%FT%TZ)" > "$DIST_DIR/manifest.json"

RELEASE_PREFIX="s3://${ARTIFACT_BUCKET}/releases/docker/${RELEASE_VERSION}"
aws s3 cp "$DIST_DIR/" "${RELEASE_PREFIX}/" --recursive --sse AES256
printf '%s\n' "$RELEASE_VERSION" |
  aws s3 cp - "s3://${ARTIFACT_BUCKET}/releases/docker-LATEST" --sse AES256

echo "Uploaded Docker release $RELEASE_VERSION to $RELEASE_PREFIX"
