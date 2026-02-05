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
LOG_ARGS=""

if [ "${GEHENNA_LOG_INPUT:-0}" = "1" ]; then
  LOG_ARGS="--log-input"
fi

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

if /usr/bin/pgrep -f GehennaDaemon >/dev/null 2>&1; then
  /usr/bin/pkill -f GehennaDaemon || true
  sleep 0.2
fi

if [ -x "$BIN_PATH" ]; then
  exec sh -c "\"$BIN_PATH\" --enable-output --seize $LOG_ARGS \"$@\" 2>&1 | tee -a \"$LOG_FILE\""
fi

swift build
exec sh -c "\"$BIN_PATH\" --enable-output --seize $LOG_ARGS \"$@\" 2>&1 | tee -a \"$LOG_FILE\""
