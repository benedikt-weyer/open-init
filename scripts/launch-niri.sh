#!/bin/sh
exec >/dev/ttyS0 2>&1

printf '%s\n' 'open-init: starting niri session'
export XDG_RUNTIME_DIR=/run/user/1001
exec /usr/bin/niri --session
