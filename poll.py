#!/usr/bin/env python3
"""Ask NZBGet what is downloading; emit one JSON line.

Invoked only by backend.sh. Two calls per poll -- `status` for the rate and the
paused flags, `listgroups` for the queue -- and nothing else touches the network.
"""

import json
import sys
import urllib.error

import nzbget


# Whether the config offered a public address at all. Reported alongside an
# "unreachable" so the bar can tell "LAN-only and away from home" -- nothing to
# fix, nothing worth a red mark -- apart from a downloader that is actually down.
HAS_PUBLIC = False


def die(msg):
    print(json.dumps({"ok": False, "error": msg, "items": [], "count": 0, "bar_text": "",
                      "has_public": HAS_PUBLIC}))
    sys.exit(1)


def main():
    global HAS_PUBLIC
    try:
        cfg = nzbget.load_config()
    except FileNotFoundError:
        die("not configured")
    except (ValueError, json.JSONDecodeError):
        die("bad config")
    HAS_PUBLIC = bool(cfg.get("public_url"))

    try:
        status = nzbget.rpc(cfg, "status")
        # Only fetch the queue when there is one. An idle NZBGet is the common
        # case and does not need a second round trip to confirm it is empty.
        busy = (int(status.get("RemainingSizeMB") or 0) > 0
                or int(status.get("PostJobCount") or 0) > 0
                or int(status.get("UrlCount") or 0) > 0)
        groups = nzbget.rpc(cfg, "listgroups") if busy else []
    except nzbget.AuthError:
        die("auth failed")
    except urllib.error.HTTPError as e:
        die("auth failed" if e.code in (401, 403) else "http %d" % e.code)
    except Exception:
        die("unreachable")

    out = nzbget.build(status, groups)
    # Surfaced so the popup can say where it is talking: on the public path the
    # poll is slower, and that is worth stating rather than leaving as a mystery.
    out["endpoint"] = nzbget.current_endpoint()
    out["has_public"] = HAS_PUBLIC
    print(json.dumps(out))


if __name__ == "__main__":
    main()
