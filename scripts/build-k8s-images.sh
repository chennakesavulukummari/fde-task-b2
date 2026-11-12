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

echo "== Validating application code & Kubernetes manifests =="
docker info >/dev/null
node --check "$REPO_ROOT/ui/app.js"
python3 -m py_compile "$REPO_ROOT/api/app.py"
grep -qi 'CREATE TABLE IF NOT EXISTS tasks' "$REPO_ROOT/db/init.sql"
for f in "$REPO_ROOT"/k8s/*.yaml; do
  [ -s "$f" ] || { echo "Missing or empty manifest: $f" >&2; exit 1; }
done

echo "== Building Docker container images for release $RELEASE_VERSION =="
docker build --pull -t "docker.io/library/fde-task-api:$RELEASE_VERSION" "$REPO_ROOT/api"
docker build --pull -t "docker.io/library/fde-task-ui:$RELEASE_VERSION" "$REPO_ROOT/ui"
docker pull docker.io/library/mysql:8.0

DIST_DIR="$REPO_ROOT/dist/k8s"
rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR/k8s" "$DIST_DIR/db"

echo "== Exporting container images archive (ui, api, mysql:8.0) =="
docker save \
  "docker.io/library/fde-task-api:$RELEASE_VERSION" \
  "docker.io/library/fde-task-ui:$RELEASE_VERSION" \
  docker.io/library/mysql:8.0 | gzip -c > "$DIST_DIR/images.tar.gz"

cp "$REPO_ROOT"/k8s/*.yaml "$DIST_DIR/k8s/"
cp "$REPO_ROOT/db/init.sql" "$DIST_DIR/db/init.sql"
(cd "$DIST_DIR" && sha256sum images.tar.gz > SHA256SUMS)
printf '{"component":"k8s-stack","version":"%s","commit":"%s","built_at":"%s"}\n' \
  "$RELEASE_VERSION" "$COMMIT_HASH" "$(date -u +%FT%TZ)" > "$DIST_DIR/manifest.json"

RELEASE_PREFIX="s3://${ARTIFACT_BUCKET}/releases/k8s/${RELEASE_VERSION}"
echo "== Uploading Kubernetes release artifacts to $RELEASE_PREFIX =="
aws s3 cp "$DIST_DIR/" "${RELEASE_PREFIX}/" --recursive --sse AES256
printf '%s\n' "$RELEASE_VERSION" |
  aws s3 cp - "s3://${ARTIFACT_BUCKET}/releases/k8s-LATEST" --sse AES256

echo "Uploaded Kubernetes release $RELEASE_VERSION to $RELEASE_PREFIX"

