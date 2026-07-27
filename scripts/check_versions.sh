#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EXPECTED_VERSION="${1#v}"
META_VERSION="$(sed -n 's/^[[:space:]]*version = "\([^"]*\)".*/\1/p' "$PROJECT_DIR/sdrbackup.koplugin/_meta.lua")"
MAIN_VERSION="$(sed -n 's/^local VERSION = "\([^"]*\)".*/\1/p' "$PROJECT_DIR/sdrbackup.koplugin/main.lua")"

if [[ -z "$EXPECTED_VERSION" || "$META_VERSION" != "$EXPECTED_VERSION" || "$MAIN_VERSION" != "$EXPECTED_VERSION" ]]; then
    printf 'Version mismatch: tag=%s meta=%s main=%s\n' "$EXPECTED_VERSION" "$META_VERSION" "$MAIN_VERSION" >&2
    exit 1
fi

printf 'Version %s is consistent.\n' "$EXPECTED_VERSION"
