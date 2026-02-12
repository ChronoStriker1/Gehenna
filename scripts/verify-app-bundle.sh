#!/bin/sh
set -eu

APP_PATH="${1:-/Applications/Gehenna.app}"

fail() {
  echo "[FAIL] $1" >&2
  exit 1
}

check_file() {
  if [ ! -f "$1" ]; then
    fail "missing file: $1"
  fi
}

check_exec() {
  if [ ! -x "$1" ]; then
    fail "missing executable: $1"
  fi
}

if [ ! -d "$APP_PATH" ]; then
  fail "app bundle not found: $APP_PATH"
fi

CONTENTS="$APP_PATH/Contents"
check_file "$CONTENTS/Info.plist"
check_exec "$CONTENTS/MacOS/GehennaApp"

CONFIGS_DIR=""
for CANDIDATE in \
  "$CONTENTS/configs" \
  "$CONTENTS/Resources/configs"
do
  if [ -d "$CANDIDATE" ]; then
    CONFIGS_DIR="$CANDIDATE"
    break
  fi
done
[ -n "$CONFIGS_DIR" ] || fail "configs directory not found"

check_file "$CONFIGS_DIR/tartarus-pro.windows-default.json"
check_file "$CONFIGS_DIR/profiles.json"
check_file "$CONFIGS_DIR/macros.json"

SCRIPTS_DIR=""
for CANDIDATE in \
  "$CONTENTS/scripts" \
  "$CONTENTS/Resources/scripts"
do
  if [ -d "$CANDIDATE" ]; then
    SCRIPTS_DIR="$CANDIDATE"
    break
  fi
done
[ -n "$SCRIPTS_DIR" ] || fail "scripts directory not found"

check_exec "$SCRIPTS_DIR/gehenna-seize.sh"
check_exec "$SCRIPTS_DIR/gehenna-stop.sh"
check_exec "$SCRIPTS_DIR/gehenna-reload.sh"

DAEMON_BIN=""
for CANDIDATE in \
  "$CONTENTS/MacOS/GehennaDaemon" \
  "$CONTENTS/.build/arm64-apple-macosx/debug/GehennaDaemon" \
  "$CONTENTS/.build/arm64-apple-macosx/release/GehennaDaemon"
do
  if [ -x "$CANDIDATE" ]; then
    DAEMON_BIN="$CANDIDATE"
    break
  fi
done

if [ -z "$DAEMON_BIN" ] && [ -d "$CONTENTS/.build" ]; then
  DAEMON_BIN="$(/usr/bin/find "$CONTENTS/.build" -type f -name GehennaDaemon -perm -u+x 2>/dev/null | /usr/bin/head -n 1 || true)"
fi
[ -n "$DAEMON_BIN" ] || fail "GehennaDaemon binary not found in app bundle"

SEIZE_CHECK="$(
  GEHENNA_CHECK_ONLY=1 GEHENNA_SKIP_SUDO=1 "$SCRIPTS_DIR/gehenna-seize.sh" 2>&1 || true
)"
echo "$SEIZE_CHECK" | /usr/bin/grep -q '^runtime_root=' || fail "seize script runtime_root resolution failed"
echo "$SEIZE_CHECK" | /usr/bin/grep -q '^daemon_bin=' || fail "seize script daemon resolution failed"

echo "[OK] App bundle verified: $APP_PATH"
echo "[OK] Configs: $CONFIGS_DIR"
echo "[OK] Scripts: $SCRIPTS_DIR"
echo "[OK] Daemon:  $DAEMON_BIN"
