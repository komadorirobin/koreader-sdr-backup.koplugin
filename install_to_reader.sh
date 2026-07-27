#!/bin/zsh
set -eu

PROJECT_DIR="${0:A:h}"
PLUGIN_DIR="$PROJECT_DIR/sdrbackup.koplugin"
SERVER_SCRIPT="$PROJECT_DIR/companion/sdr_backup_server.py"
ADB_BIN="${ADB_BIN:-adb}"

if ! command -v "$ADB_BIN" >/dev/null 2>&1; then
    print -u2 "adb hittades inte. Installera Android platform-tools först."
    exit 1
fi

if [[ -n "${ADB_SERIAL:-}" ]]; then
    ADB_ARGS=(-s "$ADB_SERIAL")
else
    ADB_ARGS=()
fi

CONFIG_JSON="$(/usr/bin/env python3 "$SERVER_SCRIPT" --print-config)"
SERVER_URL="$(print -r -- "$CONFIG_JSON" | /usr/bin/env python3 -c 'import json,sys; print(json.load(sys.stdin)["server_url"])')"
TOKEN="$(print -r -- "$CONFIG_JSON" | /usr/bin/env python3 -c 'import json,sys; print(json.load(sys.stdin)["token"])')"
TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT

{
    print 'return {'
    print "    server_url = \"$SERVER_URL\","
    print "    token = \"$TOKEN\","
    print '    active_backup_id = "",'
    print '}'
} > "$TEMP_DIR/sdrbackup_settings.lua"

"$ADB_BIN" "${ADB_ARGS[@]}" shell mkdir -p /sdcard/koreader/plugins/sdrbackup.koplugin
"$ADB_BIN" "${ADB_ARGS[@]}" push "$PLUGIN_DIR/." /sdcard/koreader/plugins/sdrbackup.koplugin/
"$ADB_BIN" "${ADB_ARGS[@]}" push "$TEMP_DIR/sdrbackup_settings.lua" /sdcard/koreader/sdrbackup_settings.lua

print
print "Plugin installerat och konfigurerat för $SERVER_URL"
print "Starta om KOReader och starta sedan start_server.command på datorn."
