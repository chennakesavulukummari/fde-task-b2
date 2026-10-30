#!/usr/bin/env bash
# CodeBuild job 1: validate ("compile") ui/api/db and push versioned artifacts to S3.
# Needs env: ARTIFACT_BUCKET
set -euo pipefail
source "$(dirname "$0")/../config.env"
: "${ARTIFACT_BUCKET:?ARTIFACT_BUCKET required}"

COMMIT="${CODEBUILD_RESOLVED_SOURCE_VERSION:-$(git rev-parse HEAD 2>/dev/null || echo local)}"
VERSION="$(date -u +%Y%m%d-%H%M%S)-${COMMIT:0:7}"
echo "Release version: $VERSION"

echo "== Validate API =="
python3 -m venv /tmp/venv
/tmp/venv/bin/pip install --quiet -r api/requirements.txt
/tmp/venv/bin/python -m py_compile api/app.py
# Import check: create_engine is lazy, so no DB connection is needed here.
( cd api && /tmp/venv/bin/python -c "import app; print('routes:', [r.path for r in app.app.routes])" )

echo "== Validate UI =="
node --check ui/app.js
grep -q '<script src="/app.js"' ui/index.html
grep -q '__API_HOST__' ui/nginx.conf.tpl

echo "== Validate DB + scripts =="
grep -qi 'CREATE TABLE IF NOT EXISTS tasks' db/init.sql
for f in deploy/*.sh scripts/*.sh; do bash -n "$f"; done

echo "== Package =="
rm -rf dist && mkdir -p dist
find . -name __pycache__ -type d -prune -exec rm -rf {} +
tar -czf dist/ui.tar.gz  ui  deploy/common.sh deploy/ui.sh
tar -czf dist/api.tar.gz api deploy/common.sh deploy/api.sh
tar -czf dist/db.tar.gz  db  deploy/common.sh deploy/db.sh
( cd dist && sha256sum *.tar.gz > SHA256SUMS )
cat > dist/manifest.json <<EOF
{"version":"$VERSION","commit":"$COMMIT","built_at":"$(date -u +%FT%TZ)","build_id":"${CODEBUILD_BUILD_ID:-local}"}
EOF
ls -l dist

echo "== Upload to s3://$ARTIFACT_BUCKET/releases/$VERSION/ =="
aws s3 cp dist/ "s3://$ARTIFACT_BUCKET/releases/$VERSION/" --recursive
echo "$VERSION" | aws s3 cp - "s3://$ARTIFACT_BUCKET/releases/LATEST"
echo "Published $VERSION (marked LATEST)"
