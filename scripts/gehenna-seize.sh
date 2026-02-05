#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
LOG_DIR="$HOME/Library/Logs/Gehenna"
LOG_FILE="$LOG_DIR/daemon.log"
BUILD_DIR="$ROOT_DIR/.build/arm64-apple-macosx/debug"
BIN_PATH="$BUILD_DIR/GehennaDaemon"

if [ "$(id -u)" -ne 0 ]; then
  exec sudo "$0" "$@"
fi

cd "$ROOT_DIR"
mkdir -p "$LOG_DIR"

if [ -x "$BIN_PATH" ]; then
  exec sh -c "\"$BIN_PATH\" --enable-output --seize \"$@\" 2>&1 | tee -a \"$LOG_FILE\""
fi

swift build
exec sh -c "\"$BIN_PATH\" --enable-output --seize \"$@\" 2>&1 | tee -a \"$LOG_FILE\""
