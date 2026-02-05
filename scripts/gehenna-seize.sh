#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
LOG_DIR="$HOME/Library/Logs/Gehenna"
LOG_FILE="$LOG_DIR/daemon.log"

if [ "$(id -u)" -ne 0 ]; then
  exec sudo "$0" "$@"
fi

cd "$ROOT_DIR"
mkdir -p "$LOG_DIR"
exec sh -c "swift run GehennaDaemon --enable-output --seize \"$@\" 2>&1 | tee -a \"$LOG_FILE\""
