#!/bin/sh
set -eu

if [ "$(/usr/bin/id -u)" -ne 0 ]; then
  if [ "${GEHENNA_SKIP_SUDO:-0}" != "1" ]; then
    if /usr/bin/sudo -n "$0" "$@" 2>/dev/null; then
      exit 0
    fi
    echo "sudo required: run 'sudo $0' once or add a sudoers rule."
    exit 1
  fi
fi

exec /usr/bin/pkill -f GehennaDaemon
