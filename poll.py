#!/usr/bin/env python3
"""Ask NZBGet what is downloading; emit one JSON line.

Invoked only by backend.sh. Two calls per poll -- `status` for the rate and the
paused flags, `listgroups` for the queue -- and nothing else touches the network.
"""

import json
import sys
import urllib.error

import nzbget


def die(msg):
    print(json.dumps({"ok": False, "error": msg, "items": [], "count": 0, "bar_text": ""}))
    sys.exit(1)


def main():
    try:
        cfg = nzbget.load_config()
    except FileNotFoundError:
        die("not configured")
    except (ValueError, json.JSONDecodeError):
        die("bad config")

    try:
        status = nzbget.rpc(cfg, "status")
        # Only fetch the queue when there is one. An idle NZBGet is the common
        # case and does not need a second round trip to confirm it is empty.
        busy = (int(status.get("RemainingSizeMB") or 0) > 0
                or int(status.get("PostJobCount") or 0) > 0
                or int(status.get("UrlCount") or 0) > 0)
        groups = nzbget.rpc(cfg, "listgroups") if busy else []
    except urllib.error.HTTPError as e:
        die("auth failed" if e.code in (401, 403) else "http %d" % e.code)
    except Exception:
        die("unreachable")

    print(json.dumps(nzbget.build(status, groups)))


if __name__ == "__main__":
    main()
