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
import urllib.request

CONFIG = os.environ.get("OMARCHY_NZBGET_CONFIG") or os.path.expanduser(
    "~/.config/omarchy-nzbget/config.json"
)


class AuthError(Exception):
    pass


def load_config():
    with open(CONFIG) as f:
        cfg = json.load(f)
    if not cfg.get("url"):
        raise ValueError("bad config")
    return cfg


def rpc(cfg, method, params=None, timeout=8):
    body = {"method": method}
    if params is not None:
        body["params"] = params
    headers = {"Content-Type": "application/json"}
    if cfg.get("user") or cfg.get("password"):
        cred = "%s:%s" % (cfg.get("user", ""), cfg.get("password", ""))
        headers["Authorization"] = "Basic " + base64.b64encode(cred.encode()).decode()
    req = urllib.request.Request(
        cfg["url"].rstrip("/") + "/jsonrpc", data=json.dumps(body).encode(), headers=headers
    )
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read()).get("result")


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
