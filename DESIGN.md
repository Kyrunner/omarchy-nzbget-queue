# ky.nzbget-queue — design

NZBGet's live download rate in the bar, and the queue behind one click.

Verified against NZBGet **26.2** on 2026-08-11.

## The bar item is a Row, not a bar button

Omarchy's two stock bar buttons each rule out half of what this widget needs:

- `BarIconButton` is a fixed square slot (`fixedWidth: slotSize`) and hides any
  label whenever `iconComponent` is set — a square icon, no text.
- `WidgetButton` renders a text label and has no icon slot at all.

A rate like `↓ 12.4 MB/s` next to a mark needs both, so the bar item is built as
a `Row { Image; Text }` inside the `BarWidget` root with its own `MouseArea`,
which is exactly what `omarchy.media` does for its glyph-plus-track-name.

The mark carries the identity, so text is only added when it says something the
icon cannot: a rate, `paused`, `processing`, or a fault. Idle needs no words —
and with `hideWhenIdle` the whole widget collapses to zero width, because a bar
already carrying a dozen items should not spend space announcing that nothing is
happening.

`BarWidget` hosting a separate `Panel.qml` also means honouring the routing
contract: `opened`, `open()`, `close()`, `popoutSwitchClosing` and
`closeForPopoutSwitch()` on the root, and injecting `bar`, `settings`,
`anchorItem` and `hostWidget` into the loaded panel.

## Formatting lives in Python

Sizes, rates, ETAs and status wording are produced by `nzbget.py`, not by QML.

This is deliberate: it is the part most likely to be wrong on data nobody has
seen, and the development machine's queue was empty throughout. Python can be
exercised against synthetic queues; QML can only be checked by eye on a machine
that happens to be downloading something.

The build step is a pure function of `(status, listgroups)`, so a fabricated
queue tests the real code path rather than a reimplementation of it.

## What it refuses to invent

**Per-item ETA only for the item actually moving.** NZBGet reports sizes, not
estimates, so ETA is `remaining ÷ current rate`. That is honest for the item
being downloaded and meaningless for anything queued behind it, whose real wait
depends on everything ahead of it. Queued items therefore carry no ETA rather
than a precise-looking fiction.

**No ETA while paused**, for the same reason: the rate is zero and any number
derived from it is invented.

**`processing`, not `↓ 0 B/s`.** When downloading finishes and NZBGet moves to
unpacking or repairing, the rate legitimately reads zero. Showing a zero rate
there looks like a stall; `PostJobCount > 0` distinguishes busy from idle.

**Plain words for NZBGet's states.** `LOADING_PARS` and `VERIFYING_REPAIRED` are
implementation detail; they render as `checking` and `verifying repair`.

## Two things only a real download revealed

Both were invisible to synthetic tests, because both come from NZBGet reporting
something subtly different from what the field names suggest.

### par2 files make a finished download read 91%

par2 blocks sit in the group as *paused*: counted in `FileSizeMB` and
`RemainingSizeMB`, but only ever fetched if a repair is needed. Measured against
the raw totals, a healthy 21.2 GB download stops at 91% and sits there through
the entire unpack, looking stalled.

Progress is therefore measured against what will actually be fetched:

```
active_total = FileSizeMB      - PausedSizeMB
active_rem   = RemainingSizeMB - PausedSizeMB
percent      = (active_total - active_rem) / active_total
```

Observed: 21.2 GB posted, ~1.9 GB of it par2, 19.3 GB actually downloaded — which
now reads 19.3 GB of 19.3 GB at 100%. Groups reporting no `PausedSizeMB` fall
back to the raw totals unchanged.

### A pause outranks the group's own status

`DownloadPaused` flips immediately; the group's `Status` and the reported
`DownloadRate` lag it by about a poll. Captured live:

```
 35s  bar='paused'  eta='2m 30s'
      ·  20%  4.3 GB/21.2 GB  downloading  eta='2m 49s'
 40s  bar='paused'  eta=''
      ·  20%  4.3 GB/21.2 GB  queued       eta=''
```

For one cycle the row claimed to be downloading, with a confident ETA, on a queue
that had already stopped. Testing `rate > 0` was not enough — the global pause is
checked explicitly, and a paused queue suppresses every ETA and renders its rows
as `paused` regardless of what the group still calls itself.

## Polling

| Situation | Interval |
|-----------|----------|
| Something downloading | 3s — a rate readout needs that to feel live |
| Queue empty | 15s — an idle server does not deserve a laptop wakeup every 3s |
| Poll failing | 5s retry, until it has been failing for 45s |
| Failing past 45s | back to the steady interval — it is a fault now, not a retry |

`listgroups` is only requested when `status` reports remaining bytes, post jobs
or URLs pending, so an idle poll is a single small request.

## The grace window

The bar starts about ten seconds before WiFi associates, so the first poll of
every boot fails. Rendering that is a lie with a red badge on it.

`Readiness.qml` (logic in `Readiness.js`, tested with `node Readiness.test.js`)
holds the rule, and it is uniform — there is no startup special case. **A failure
is silent until it has lasted 45 seconds of continuous failing.** It retries every
5s meanwhile, and one success anywhere in that window resets the clock. So a boot
is quiet, a blip is quiet, and a genuinely dead downloader still speaks up within
a minute.

That 45s is real elapsed time, accumulated one poll at a time with each interval
sanity-checked against the delay actually scheduled. It has to be:
`systemd-timesyncd` makes its first correction inside this very window, and a
suspend moves the clock by hours. A step in either direction is credited as one
scheduled interval, so it can neither manufacture a fault nor hide one.

## Bar states

| State | Bar shows |
|-------|-----------|
| Nothing downloading | hidden (configurable: mark only, no text) |
| Downloading | mark + `↓ 12.4 MB/s` |
| Paused | mark dimmed + `paused` |
| Post-processing | mark + `processing` |
| Failing < 45s, nothing known yet | hidden — the boot case, before the first poll lands |
| Failing < 45s, queue known | unchanged: last known rate, popup marks it last-known |
| not configured / unreachable / auth failed for 45s | mark dimmed + red `!` |

A fault keeps its width instead of collapsing, so "broken" and "idle" never look
the same. The undecided window is the one case that hides rather than keeping its
width, and only when there is nothing to show — a widget that has a queue keeps
showing it rather than blinking out of the bar mid-session.

## Two endpoints, and why the order matters

`public_url` is optional and exists so the widget keeps working away from home.
The LAN address is always tried first, and not merely because it is faster: at 3s
polling this widget makes ~28,800 requests a day, and aiming that at a public
edge running a rate limiter or an IP-ban daemon gets you banned from your own
server.

The choice is persisted to `~/.local/state/omarchy-nzbget/endpoint.json` because
`backend.sh` is a fresh process per poll — with no memory, every poll away from
home would pay the LAN timeout before falling back. After a fallback it sticks to
the public endpoint for 10 minutes, then re-probes, so walking back in the front
door restores the LAN path unaided. A sticky choice that has gone stale gets one
full retry rather than staying wedged.

`AuthError` deliberately never triggers failover. Bad credentials are not an
endpoint problem, and retrying them against a public edge is how you get banned
by your own defences.

## Credentials

HTTP Basic against NZBGet's ControlUsername/ControlPassword. The config path is
passed to the helpers through the environment rather than argv, so credentials
never appear in `ps` for other users on the box.

The only thing the plugin writes is `~/.local/state/omarchy-nzbget/endpoint.json`
— which address last worked. It reads its config and never edits it.

## Testing status

Verified live: auth, `status`, pause/resume round-trip, speed-limit argument
validation, every error path, the bar item in idle / paused / fault states, and
the popup.

Verified against a real 21.2 GB download: percentages, sizes, ETA counting down
from 3m 17s to 0s, the pause/resume transition, the handover to post-processing
without a `0 B/s` flash, `unpacking` / `renaming` / `running script` all mapping
to plain words, and the widget disappearing on completion.

That run is also what surfaced both defects documented above.

## Out of scope

- Adding NZBs. Radarr and Sonarr do that; this watches the result.
- History browsing and per-item delete. The NZBGet web UI is better at both.
- Notifications on completion. The `*arr` stack already announces itself.
