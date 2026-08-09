#!/bin/sh
exec >/dev/ttyS0 2>&1

printf '%s\n' 'open-init: starting niri session'
export XDG_RUNTIME_DIR=/run/user/1001
export LIBSEAT_BACKEND=seatd
export XCURSOR_THEME=DMZ-White
export XCURSOR_PATH=/usr/share/icons
exec /usr/bin/niri --session
