#!/usr/bin/env bash
# NZBGet download queue -> one compact JSON line on stdout.
#
# The ONLY entry point into this plugin's network surface. Kept as scripts, not
# QML, so the whole thing can be run and diffed over SSH — the widget itself can
# only be checked by eye on the owner's screen.
#
#   backend.sh                    poll; print rate, queue and disk
#   backend.sh pause              pause downloading
#   backend.sh resume             resume downloading
#   backend.sh limit <kbps>       speed limit in KB/s, 0 = unlimited
#
#   {"ok":true,"bar_text":"↓ 12.4 MB/s","count":3,"items":[{...}]}
#   {"ok":false,"error":"not configured","items":[],"count":0}   and a non-zero exit
#
# Config: ~/.config/omarchy-nzbget/config.json
#   {"url":"http://host:6789","user":"...","password":"..."}
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CFG="${OMARCHY_NZBGET_CONFIG:-$HOME/.config/omarchy-nzbget/config.json}"

[ -r "$CFG" ] || { printf '{"ok":false,"error":"not configured","items":[],"count":0,"bar_text":""}\n'; exit 1; }

# Credentials reach the helpers through the config path in the environment, never
# through argv, so they do not show up in `ps` for every other user on the box.
export OMARCHY_NZBGET_CONFIG="$CFG"

case "${1:-poll}" in
  poll)             exec python3 "$DIR/poll.py" ;;
  pause|resume)     exec python3 "$DIR/control.py" "$1" ;;
  limit)
    [ $# -eq 2 ] || { printf '{"ok":false,"error":"usage: limit <kbps>"}\n'; exit 1; }
    exec python3 "$DIR/control.py" limit "$2"
    ;;
  *)
    printf '{"ok":false,"error":"unknown command","items":[],"count":0,"bar_text":""}\n'
    exit 1
    ;;
esac
