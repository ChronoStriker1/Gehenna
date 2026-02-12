#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
PLIST_SOURCE="$ROOT_DIR/launchd/com.gehenna.daemon.plist"
PLIST_DEST="$HOME/Library/LaunchAgents/com.gehenna.daemon.plist"
LOG_DIR="$HOME/Library/Logs/Gehenna"
SCRIPT_PATH="$ROOT_DIR/scripts/gehenna-seize.sh"
LOG_FILE="$LOG_DIR/daemon.log"

if [ ! -f "$PLIST_SOURCE" ]; then
  echo "Missing launchd template: $PLIST_SOURCE"
  exit 1
fi

if [ ! -x "$SCRIPT_PATH" ]; then
  echo "Missing executable seize script: $SCRIPT_PATH"
  exit 1
fi

mkdir -p "$LOG_DIR"
mkdir -p "$HOME/Library/LaunchAgents"

ESCAPED_SCRIPT="$(printf '%s\n' "$SCRIPT_PATH" | /usr/bin/sed 's/[\\/&]/\\&/g')"
ESCAPED_LOG="$(printf '%s\n' "$LOG_FILE" | /usr/bin/sed 's/[\\/&]/\\&/g')"
/usr/bin/sed \
  -e "s/__GEHENNA_SEIZE_SCRIPT__/$ESCAPED_SCRIPT/g" \
  -e "s/__GEHENNA_DAEMON_LOG__/$ESCAPED_LOG/g" \
  "$PLIST_SOURCE" > "$PLIST_DEST"

launchctl unload "$PLIST_DEST" >/dev/null 2>&1 || true
launchctl load "$PLIST_DEST"
launchctl start com.gehenna.daemon || true

echo "Installed LaunchAgent at $PLIST_DEST"
