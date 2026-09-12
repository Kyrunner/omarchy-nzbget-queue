#!/usr/bin/env python3
"""Shared NZBGet plumbing: config, JSON-RPC, and the presentation formatting.

Formatting lives here rather than in QML on purpose. It is the part most likely
to be wrong on data nobody has seen yet -- an empty queue cannot exercise a
progress bar -- and Python can be tested against synthetic queues while QML can
only be checked by eye on a machine that happens to be downloading something.
"""

import base64
import json
import os
import stat
import time
import urllib.error
import urllib.parse
import urllib.request

CONFIG = os.environ.get("OMARCHY_NZBGET_CONFIG") or os.path.expanduser(
    "~/.config/omarchy-nzbget/config.json"
)
STATE_DIR = os.path.join(
    os.environ.get("XDG_STATE_HOME") or os.path.expanduser("~/.local/state"),
    "omarchy-nzbget",
)
ENDPOINT_FILE = os.path.join(STATE_DIR, "endpoint.json")

# Long enough that moving around the house does not thrash the choice, short
# enough that coming home restores the LAN path without intervention.
PUBLIC_STICKY_SEC = 600
LAN_TIMEOUT = 2.5
PUBLIC_TIMEOUT = 10

# A reply is read up to this many bytes and no further. `listgroups` for a long
# queue is tens of KB; anything past this is not NZBGet answering us.
MAX_RESPONSE_BYTES = 4 * 1024 * 1024


class AuthError(Exception):
    """Bad credentials. Deliberately never triggers endpoint failover: retrying a
    wrong password against a public edge is how you get banned by your own rate
    limiter."""


class EndpointRefused(Exception):
    """The endpoint is not one the credentials may be sent to, or its reply is not
    one we will parse. The message is what the widget shows."""


class _NoRedirects(urllib.request.HTTPRedirectHandler):
    """urllib copies request headers onto a redirected request, so following a 3xx
    would replay the Basic-auth header to wherever Location points. Returning None
    makes the redirect surface as an HTTPError instead."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


_OPENER = urllib.request.build_opener(_NoRedirects)


def load_config():
    with open(CONFIG) as f:
        cfg = json.load(f)
    if not (cfg.get("url") or cfg.get("public_url")):
        raise ValueError("bad config")
    return cfg


def _state_dir_fd():
    """A descriptor for the state directory, or an exception.

    Every state read and write goes through this one descriptor rather than
    through a path, so the directory cannot be swapped for another between the
    check below and the operation that trusts it. O_NOFOLLOW means a symlink
    standing where the directory should be is an error, not a redirect.
    """
    os.makedirs(STATE_DIR, mode=0o700, exist_ok=True)
    fd = os.open(STATE_DIR, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        st = os.fstat(fd)
        if st.st_uid != os.getuid():
            raise PermissionError("state directory is not ours")
        if st.st_mode & (stat.S_IWGRP | stat.S_IWOTH):
            # Anyone who can write here can plant the file we are about to open.
            raise PermissionError("state directory is writable by others")
    except Exception:
        os.close(fd)
        raise
    return fd


def _load_json(path, default):
    dfd = None
    try:
        dfd = _state_dir_fd()
        fd = os.open(os.path.basename(path), os.O_RDONLY | os.O_NOFOLLOW, dir_fd=dfd)
        with os.fdopen(fd) as f:
            return json.load(f)
    except Exception:
        return default
    finally:
        if dfd is not None:
            os.close(dfd)


def _save_json(path, data):
    """Publish state atomically, without trusting anything already on disk.

    The temp name is random and created with O_EXCL, so a file already sitting
    at that name is a failure rather than something to write through; O_NOFOLLOW
    means a symlink there is never followed. Without both, the predictable
    "<file>.tmp" name let anything that could write this directory choose which
    file the poll truncated.
    """
    name = os.path.basename(path)
    dfd = None
    tmp = None
    try:
        dfd = _state_dir_fd()
        tmp = ".%s.%s.tmp" % (name, os.urandom(8).hex())
        fd = os.open(
            tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=dfd
        )
        with os.fdopen(fd, "w") as f:
            json.dump(data, f)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, name, src_dir_fd=dfd, dst_dir_fd=dfd)
        tmp = None
    except Exception:
        pass  # remembering the endpoint is an optimisation, never a requirement
    finally:
        if dfd is not None:
            if tmp is not None:
                try:
                    os.unlink(tmp, dir_fd=dfd)
                except OSError:
                    pass
            os.close(dfd)


def _post(which, base, cfg, method, params, timeout):
    url = base.rstrip("/") + "/jsonrpc"
    # The LAN address may be plain HTTP on a trusted network; the public one
    # carries the credentials across the internet and must be HTTPS.
    if which == "public" and urllib.parse.urlsplit(url).scheme != "https":
        raise EndpointRefused("public_url must be https")
    body = {"method": method}
    if params is not None:
        body["params"] = params
    headers = {"Content-Type": "application/json"}
    if cfg.get("user") or cfg.get("password"):
        cred = "%s:%s" % (cfg.get("user", ""), cfg.get("password", ""))
        headers["Authorization"] = "Basic " + base64.b64encode(cred.encode()).decode()
    req = urllib.request.Request(url, data=json.dumps(body).encode(), headers=headers)
    try:
        with _OPENER.open(req, timeout=timeout) as r:
            if r.geturl() != url:
                raise EndpointRefused("redirected")
            raw = r.read(MAX_RESPONSE_BYTES + 1)
            if len(raw) > MAX_RESPONSE_BYTES:
                raise EndpointRefused("response too large")
            return json.loads(raw).get("result")
    except urllib.error.HTTPError as e:
        if e.code in (401, 403):
            raise AuthError("auth failed")
        raise


def rpc(cfg, method, params=None, timeout=None):
    """Call NZBGet, preferring the LAN address and falling back to the public one.

    The endpoint choice is persisted because these scripts run as a fresh process
    per poll: with no memory, every poll away from home would pay the LAN timeout
    before falling back.
    """
    lan, public = cfg.get("url"), cfg.get("public_url")
    state = _load_json(ENDPOINT_FILE, {})
    on_public = state.get("which") == "public"
    fresh = (time.time() - float(state.get("since") or 0)) < PUBLIC_STICKY_SEC

    if on_public and fresh and public:
        order = [("public", public, timeout or PUBLIC_TIMEOUT)]
    else:
        order = ([("lan", lan, timeout or LAN_TIMEOUT)] if lan else []) + \
                ([("public", public, timeout or PUBLIC_TIMEOUT)] if public else [])

    last = None
    for which, base, tmo in order:
        try:
            result = _post(which, base, cfg, method, params, tmo)
            if which != state.get("which") or which == "public":
                _save_json(ENDPOINT_FILE, {"which": which, "since": time.time()})
            return result
        except AuthError:
            raise      # not an endpoint problem; do not hammer the public edge with it
        except Exception as e:
            last = e

    # A sticky public choice can go stale (came home, wifi changed). One retry of
    # the full order beats staying wedged on an endpoint that is gone.
    if on_public and fresh and lan:
        _save_json(ENDPOINT_FILE, {})
        return rpc(cfg, method, params, timeout)

    raise last or RuntimeError("no endpoint configured")


def current_endpoint():
    return _load_json(ENDPOINT_FILE, {}).get("which") or "lan"


# ---- formatting -------------------------------------------------------------

def fmt_rate(bytes_per_sec):
    """NZBGet reports DownloadRate in bytes/sec.

    Above 10 MB/s the decimal is dropped. This is a layout decision, not a
    precision one: the rate is the bar's own label, so every change in its width
    shoves every widget to its right. On a fast connection `96.3` / `100.2` /
    `117.1` jitters on almost every poll, while whole numbers only change width
    crossing 9->10 and 99->100. Below 10 MB/s the decimal is worth more than the
    stability, because 4.2 and 4.9 are meaningfully different speeds.
    """
    b = float(bytes_per_sec or 0)
    if b <= 0:
        return "0 B/s"
    for unit, div in (("GB/s", 1024 ** 3), ("MB/s", 1024 ** 2), ("KB/s", 1024)):
        if b >= div:
            v = b / div
            if unit == "MB/s" and v >= 10:
                return "%d %s" % (round(v), unit)
            return "%.1f %s" % (v, unit)
    return "%d B/s" % int(b)


def fmt_size(mb):
    """Sizes arrive in MB. Below a gigabyte, decimals are noise."""
    m = float(mb or 0)
    if m >= 1024:
        return "%.1f GB" % (m / 1024)
    return "%d MB" % int(round(m))


def fmt_eta(seconds):
    """No ETA at all beats a fabricated one, so None in means empty string out."""
    if seconds is None or seconds < 0:
        return ""
    s = int(seconds)
    if s < 60:
        return "%ds" % s
    if s < 3600:
        return "%dm %ds" % (s // 60, s % 60)
    h, rem = divmod(s, 3600)
    if h >= 24:
        return "%dd %dh" % (h // 24, h % 24)
    return "%dh %dm" % (h, rem // 60)


# NZBGet's raw status strings are SHOUTY_SNAKE_CASE and leak implementation
# detail (LOADING_PARS means nothing to someone watching a download).
STATUS_TEXT = {
    "QUEUED": "queued",
    "PAUSED": "paused",
    "DOWNLOADING": "downloading",
    "FETCHING": "fetching",
    "PP_QUEUED": "waiting to process",
    "LOADING_PARS": "checking",
    "VERIFYING_SOURCES": "verifying",
    "REPAIRING": "repairing",
    "VERIFYING_REPAIRED": "verifying repair",
    "RENAMING": "renaming",
    "UNPACKING": "unpacking",
    "MOVING": "moving",
    "EXECUTING_SCRIPT": "running script",
    "PP_FINISHED": "finished",
}


def status_text(raw):
    return STATUS_TEXT.get(raw or "", (raw or "").replace("_", " ").lower())


def build(status, groups):
    """Turn a raw (status, listgroups) pair into everything the widget renders.

    Split out from the polling so it can be exercised against synthetic queues.
    """
    status = status or {}
    groups = groups or []

    rate = int(status.get("DownloadRate") or 0)
    paused = bool(status.get("DownloadPaused") or status.get("ServerPaused"))
    remaining_mb = float(status.get("RemainingSizeMB") or 0)
    post_jobs = int(status.get("PostJobCount") or 0)

    # Overall ETA only means anything while bytes are actually moving. Paused, or
    # mid-repair with the rate at zero, any number here would be a fiction.
    #
    # `paused` is checked explicitly rather than relying on the rate: NZBGet flips
    # DownloadPaused immediately but keeps reporting the last rate for a poll or
    # so afterwards, which is long enough to show a confident ETA on a queue that
    # has already stopped.
    eta_sec = None
    if rate > 0 and remaining_mb > 0 and not paused:
        eta_sec = int((remaining_mb * 1024 * 1024) / rate)

    items = []
    for g in groups:
        size_mb = float(g.get("FileSizeMB") or 0)
        rem_mb = float(g.get("RemainingSizeMB") or 0)

        # par2 files sit in the group as *paused*: counted in FileSizeMB and
        # RemainingSizeMB, but only ever downloaded if a repair is needed. Measured
        # against the raw totals, a healthy download finishes at 91% and sits there
        # through the whole unpack looking stalled. Progress has to be measured
        # against what will actually be fetched.
        paused_mb = float(g.get("PausedSizeMB") or 0)
        active_total = max(0.0, size_mb - paused_mb)
        active_rem = max(0.0, rem_mb - paused_mb)
        done_mb = max(0.0, active_total - active_rem)
        pct = int(round((done_mb / active_total) * 100)) if active_total > 0 else 0
        raw_status = g.get("Status") or ""
        # A global pause outranks the group's own status, which lags it by a poll:
        # left alone, a paused queue shows a row still calling itself
        # "downloading". The group is not downloading -- the whole queue stopped.
        active = raw_status in ("DOWNLOADING", "FETCHING") and not paused
        item_paused = paused or raw_status == "PAUSED"

        # Per-item ETA only for the item actually moving. NZBGet downloads
        # sequentially, so a queued item's "ETA" would depend on everything ahead
        # of it -- a number that looks precise and is not.
        item_eta = None
        if active and rate > 0 and rem_mb > 0:
            item_eta = int((rem_mb * 1024 * 1024) / rate)

        items.append({
            "id": g.get("NZBID"),
            "name": g.get("NZBName") or g.get("NZBNicename") or "unnamed",
            "category": g.get("Category") or "",
            "size_text": fmt_size(active_total),
            "done_text": fmt_size(done_mb),
            "percent": max(0, min(100, pct)),
            "status": "paused" if item_paused else status_text(raw_status),
            "raw_status": raw_status,
            "active": active,
            "paused": item_paused,
            "eta_text": fmt_eta(item_eta),
        })

    # What the bar says, in priority order: a fault is handled by the caller, a
    # pause outranks a rate, and post-processing outranks an idle rate of zero --
    # showing "0 B/s" while NZBGet is busy unpacking reads as broken.
    if paused:
        bar_text = "paused"
    elif rate > 0:
        bar_text = "↓ " + fmt_rate(rate)
    elif post_jobs > 0:
        bar_text = "processing"
    elif items:
        bar_text = "↓ 0 B/s"
    else:
        bar_text = ""

    return {
        "ok": True,
        "rate_text": fmt_rate(rate),
        "rate_bps": rate,
        "bar_text": bar_text,
        "paused": paused,
        "post_jobs": post_jobs,
        "remaining_text": fmt_size(remaining_mb),
        "eta_text": fmt_eta(eta_sec),
        "limit_kbps": int(status.get("DownloadLimit") or 0),
        "free_disk_text": fmt_size(float(status.get("FreeDiskSpaceMB") or 0)),
        "free_disk_mb": int(status.get("FreeDiskSpaceMB") or 0),
        "count": len(items),
        "items": items,
    }
