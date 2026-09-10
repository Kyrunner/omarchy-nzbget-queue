#!/usr/bin/env bash
# What poll.py says about itself when NZBGet cannot be reached.
#
#   bash poll-output.test.sh
#
# Needs no server: every case points at a port nothing listens on, so the poll
# fails fast and deterministically. The point is the `has_public` flag, which
# lets the bar tell "LAN-only and away from home" apart from a real fault.
set -u

PLUGIN="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export XDG_STATE_HOME="$WORK/state"   # keep the endpoint memory out of the real one

DEAD="http://127.0.0.1:1"
pass=0
fail=0

run() { # name, expected-substring, config-json
  local name="$1" want="$2" cfg="$3" out
  printf '%s' "$cfg" >"$WORK/config.json"
  out=$(OMARCHY_NZBGET_CONFIG="$WORK/config.json" "$PLUGIN/backend.sh" 2>&1)
  if [[ "$out" == *"$want"* ]]; then
    pass=$((pass + 1)); printf '  ok    %s\n' "$name"
  else
    fail=$((fail + 1)); printf '  FAIL  %s\n        want %s\n        got  %s\n' "$name" "$want" "$out"
  fi
}

echo "unreachable, and whether a public address was there to try:"
run "LAN only, dead"              '"has_public": false' "{\"url\":\"$DEAD\",\"user\":\"u\",\"password\":\"p\"}"
run "LAN only, public_url empty"  '"has_public": false' "{\"url\":\"$DEAD\",\"public_url\":\"\",\"user\":\"u\",\"password\":\"p\"}"
run "both dead"                   '"has_public": true'  "{\"url\":\"$DEAD\",\"public_url\":\"http://127.0.0.1:2\",\"user\":\"u\",\"password\":\"p\"}"
run "both dead is still unreachable" '"error": "unreachable"' "{\"url\":\"$DEAD\",\"public_url\":\"http://127.0.0.1:2\",\"user\":\"u\",\"password\":\"p\"}"

echo
if [ "$fail" -eq 0 ]; then
  echo "poll output: all $pass assertions passed"
else
  echo "poll output: $fail of $((pass + fail)) failed"
fi
[ "$fail" -eq 0 ]
