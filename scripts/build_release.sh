#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$PROJECT_DIR/dist"
ZIP_PATH="$DIST_DIR/sdrbackup.koplugin.zip"
CHECKSUM_PATH="$ZIP_PATH.sha256"
PLUGIN_DIR="$PROJECT_DIR/sdrbackup.koplugin"

if command -v sha256sum >/dev/null 2>&1; then
    (cd "$PLUGIN_DIR" && sha256sum main.lua sdrbackup_updater.lua _meta.lua > files.sha256)
else
    (cd "$PLUGIN_DIR" && shasum -a 256 main.lua sdrbackup_updater.lua _meta.lua > files.sha256)
fi

mkdir -p "$DIST_DIR"
find "$DIST_DIR" -maxdepth 1 -type f \( -name 'sdrbackup.koplugin.zip' -o -name 'sdrbackup.koplugin.zip.sha256' \) -delete

cd "$PROJECT_DIR"
COPYFILE_DISABLE=1 zip -q -r "$ZIP_PATH" sdrbackup.koplugin \
    -x '*.DS_Store' -x '._*' -x '*/__pycache__/*'

if command -v sha256sum >/dev/null 2>&1; then
    (cd "$DIST_DIR" && sha256sum "$(basename "$ZIP_PATH")" > "$(basename "$CHECKSUM_PATH")")
else
    (cd "$DIST_DIR" && shasum -a 256 "$(basename "$ZIP_PATH")" > "$(basename "$CHECKSUM_PATH")")
fi

unzip -tq "$ZIP_PATH" >/dev/null
printf 'Built %s\n' "$ZIP_PATH"
