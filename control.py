#!/usr/bin/env python3
"""Pause, resume, or speed-limit NZBGet.

    control.py pause
    control.py resume
    control.py limit <kbps>     # 0 = unlimited
"""

import json
import sys
import urllib.error

import nzbget


def out(ok, **kw):
    print(json.dumps({"ok": ok, **kw}))
    sys.exit(0 if ok else 1)


def main():
    args = sys.argv[1:]
    if not args or args[0] not in ("pause", "resume", "limit"):
        out(False, error="usage: control.py <pause|resume|limit <kbps>>")
    action = args[0]

    kbps = None
    if action == "limit":
        if len(args) != 2 or not args[1].lstrip("-").isdigit():
            out(False, error="limit needs a whole number of KB/s (0 = unlimited)")
        kbps = int(args[1])
        if kbps < 0:
            out(False, error="limit cannot be negative")

    try:
        cfg = nzbget.load_config()
    except FileNotFoundError:
        out(False, error="not configured")
    except Exception:
        out(False, error="bad config")

    try:
        if action == "pause":
            nzbget.rpc(cfg, "pausedownload")
        elif action == "resume":
            nzbget.rpc(cfg, "resumedownload")
        else:
            nzbget.rpc(cfg, "rate", [kbps])
    except urllib.error.HTTPError as e:
        out(False, error="auth failed" if e.code in (401, 403) else "http %d" % e.code)
    except Exception:
        out(False, error="unreachable")

    out(True, action=action, **({"kbps": kbps} if kbps is not None else {}))


if __name__ == "__main__":
    main()
