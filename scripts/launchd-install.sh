#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
PLIST_SOURCE="$ROOT_DIR/launchd/com.gehenna.daemon.plist"
PLIST_DEST="$HOME/Library/LaunchAgents/com.gehenna.daemon.plist"
LOG_DIR="$HOME/Library/Logs/Gehenna"

mkdir -p "$LOG_DIR"
mkdir -p "$HOME/Library/LaunchAgents"
cp "$PLIST_SOURCE" "$PLIST_DEST"

launchctl unload "$PLIST_DEST" >/dev/null 2>&1 || true
launchctl load "$PLIST_DEST"
launchctl start com.gehenna.daemon || true

echo "Installed LaunchAgent at $PLIST_DEST"
