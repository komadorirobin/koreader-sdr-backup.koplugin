#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TAG="${1:-}"

if [[ ! "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    printf 'Usage: %s vX.Y.Z\n' "$0" >&2
    exit 1
fi

cd "$PROJECT_DIR"
./scripts/check_versions.sh "$TAG"
luajit -b sdrbackup.koplugin/main.lua /tmp/sdrbackup-main.luac
luajit -b sdrbackup.koplugin/sdrbackup_updater.lua /tmp/sdrbackup-updater.luac
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests -v
./scripts/build_release.sh

if ! git diff --quiet || ! git diff --cached --quiet; then
    printf 'Working tree must be clean before publishing.\n' >&2
    exit 1
fi

git tag -a "$TAG" -m "SDR Backup $TAG"
git push origin main "$TAG"
gh release create "$TAG" \
    dist/sdrbackup.koplugin.zip \
    dist/sdrbackup.koplugin.zip.sha256 \
    --generate-notes \
    --title "SDR Backup $TAG"
