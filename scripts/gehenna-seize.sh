#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
if [ -n "${SUDO_USER:-}" ]; then
  USER_HOME="$(eval echo "~$SUDO_USER")"
else
  USER_HOME="$HOME"
fi
LOG_DIR="$USER_HOME/Library/Logs/Gehenna"
LOG_FILE="$LOG_DIR/daemon.log"
BUILD_DIR="$ROOT_DIR/.build/arm64-apple-macosx/debug"
BIN_PATH="$BUILD_DIR/GehennaDaemon"

if [ "$(id -u)" -ne 0 ]; then
  if sudo -n "$0" "$@" 2>/dev/null; then
    exit 0
  fi
  echo "sudo required: run 'sudo $0' once or add a sudoers rule."
  echo "If this runs from the GUI, also add: Defaults:chronostriker1 !requiretty"
  exit 1
fi

cd "$ROOT_DIR"
mkdir -p "$LOG_DIR"
 : > "$LOG_FILE"

if [ -x "$BIN_PATH" ]; then
  exec sh -c "\"$BIN_PATH\" --enable-output --seize \"$@\" 2>&1 | tee -a \"$LOG_FILE\""
fi

swift build
exec sh -c "\"$BIN_PATH\" --enable-output --seize \"$@\" 2>&1 | tee -a \"$LOG_FILE\""
