#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
PARENT_ROOT="$(CDPATH= cd -- "$ROOT_DIR/.." && pwd)"
if [ -n "${SUDO_USER:-}" ]; then
  USER_HOME="$(eval echo "~$SUDO_USER")"
else
  USER_HOME="$HOME"
fi
LOG_DIR="$USER_HOME/Library/Logs/Gehenna"
LOG_FILE="$LOG_DIR/daemon.log"
LOG_ARGS=""

resolve_runtime_root() {
  if [ -d "$ROOT_DIR/configs" ]; then
    printf '%s\n' "$ROOT_DIR"
    return
  fi
  if [ -d "$PARENT_ROOT/configs" ]; then
    printf '%s\n' "$PARENT_ROOT"
    return
  fi
  printf '%s\n' "$ROOT_DIR"
}

find_build_daemon() {
  BUILD_BASE="$1"
  if [ ! -d "$BUILD_BASE" ]; then
    return 1
  fi
  /usr/bin/find "$BUILD_BASE" -type f -name GehennaDaemon -perm -u+x 2>/dev/null \
    | /usr/bin/grep -E '/(debug|release)/GehennaDaemon$' \
    | /usr/bin/sort \
    | /usr/bin/head -n 1
}

resolve_daemon_bin() {
  for CANDIDATE in \
    "$ROOT_DIR/MacOS/GehennaDaemon" \
    "$PARENT_ROOT/MacOS/GehennaDaemon"
  do
    if [ -x "$CANDIDATE" ]; then
      printf '%s\n' "$CANDIDATE"
      return 0
    fi
  done

  for BUILD_BASE in \
    "$ROOT_DIR/.build" \
    "$PARENT_ROOT/.build"
  do
    BIN="$(find_build_daemon "$BUILD_BASE" || true)"
    if [ -n "$BIN" ] && [ -x "$BIN" ]; then
      printf '%s\n' "$BIN"
      return 0
    fi
  done

  return 1
}

if [ "${GEHENNA_LOG_INPUT:-0}" = "1" ]; then
  LOG_ARGS="--log-input"
fi

SEIZE_FALLBACK_ARG=""
if [ "${GEHENNA_SEIZE_FALLBACK:-1}" = "1" ]; then
  SEIZE_FALLBACK_ARG="--seize-fallback"
fi

if [ "$(/usr/bin/id -u)" -ne 0 ]; then
  if [ "${GEHENNA_SKIP_SUDO:-0}" != "1" ]; then
    if /usr/bin/sudo -n "$0" "$@" 2>/dev/null; then
      exit 0
    fi
    if [ "${GEHENNA_REQUIRE_SUDO:-0}" = "1" ]; then
      echo "sudo required: run 'sudo $0' once or add a sudoers rule."
      echo "If this runs from the GUI, also add: Defaults:chronostriker1 !requiretty"
      exit 1
    fi
    echo "sudo unavailable; continuing without sudo."
  fi
fi

RUNTIME_ROOT="$(resolve_runtime_root)"
mkdir -p "$LOG_DIR"
 : > "$LOG_FILE"
if [ -n "${SUDO_USER:-}" ]; then
  /usr/sbin/chown "$SUDO_USER" "$LOG_DIR" "$LOG_FILE" 2>/dev/null || true
fi
/bin/chmod 755 "$LOG_DIR" 2>/dev/null || true
/bin/chmod 664 "$LOG_FILE" 2>/dev/null || true

if /usr/bin/pgrep -f GehennaDaemon >/dev/null 2>&1; then
  /usr/bin/pkill -f GehennaDaemon || true
  sleep 0.2
fi

BIN_PATH="$(resolve_daemon_bin || true)"

if [ -z "$BIN_PATH" ]; then
  BUILD_ROOT=""
  if [ -f "$ROOT_DIR/Package.swift" ]; then
    BUILD_ROOT="$ROOT_DIR"
  elif [ -f "$PARENT_ROOT/Package.swift" ]; then
    BUILD_ROOT="$PARENT_ROOT"
  fi

  if [ -n "$BUILD_ROOT" ]; then
    SWIFT_BIN="$(/usr/bin/xcrun -f swift 2>/dev/null || true)"
    if [ -z "$SWIFT_BIN" ]; then
      echo "swift toolchain not found; cannot build GehennaDaemon."
      exit 1
    fi
    (cd "$BUILD_ROOT" && "$SWIFT_BIN" build)
    BIN_PATH="$(resolve_daemon_bin || true)"
  fi
fi

if [ -z "$BIN_PATH" ] || [ ! -x "$BIN_PATH" ]; then
  echo "GehennaDaemon binary not found. Expected one of:"
  echo "  $ROOT_DIR/.build/*/{debug,release}/GehennaDaemon"
  echo "  $PARENT_ROOT/.build/*/{debug,release}/GehennaDaemon"
  echo "  $ROOT_DIR/MacOS/GehennaDaemon"
  echo "  $PARENT_ROOT/MacOS/GehennaDaemon"
  exit 1
fi

cd "$RUNTIME_ROOT"
if [ "${GEHENNA_CHECK_ONLY:-0}" = "1" ]; then
  echo "runtime_root=$RUNTIME_ROOT"
  echo "daemon_bin=$BIN_PATH"
  echo "log_file=$LOG_FILE"
  exit 0
fi

# Preserve daemon exit status so GUI can detect failure and run fallback startup logic.
if [ "$(/usr/bin/id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ] && [ "${GEHENNA_RUN_DAEMON_AS_SUDO_USER:-1}" = "1" ]; then
  exec /usr/bin/sudo -n -u "$SUDO_USER" -- \
    "$BIN_PATH" --enable-output --seize $SEIZE_FALLBACK_ARG $LOG_ARGS "$@" >> "$LOG_FILE" 2>&1
fi

exec "$BIN_PATH" --enable-output --seize $SEIZE_FALLBACK_ARG $LOG_ARGS "$@" >> "$LOG_FILE" 2>&1
