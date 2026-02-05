#!/bin/sh
set -eu

PLIST_DEST="$HOME/Library/LaunchAgents/com.gehenna.daemon.plist"

launchctl unload "$PLIST_DEST" >/dev/null 2>&1 || true
rm -f "$PLIST_DEST"

echo "Removed LaunchAgent at $PLIST_DEST"
