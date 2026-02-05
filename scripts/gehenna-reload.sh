#!/bin/sh
set -eu

if [ "$(id -u)" -ne 0 ]; then
  exec sudo "$0" "$@"
fi

exec /usr/bin/pkill -USR1 -f GehennaDaemon
