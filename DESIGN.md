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

`listgroups` is only requested when `status` reports remaining bytes, post jobs
or URLs pending, so an idle poll is a single small request.

## Bar states

| State | Bar shows |
|-------|-----------|
| Nothing downloading | hidden (configurable: mark only, no text) |
| Downloading | mark + `↓ 12.4 MB/s` |
| Paused | mark dimmed + `paused` |
| Post-processing | mark + `processing` |
| not configured / unreachable / auth failed | mark dimmed + red `!` |

A fault keeps its width instead of collapsing, so "broken" and "idle" never look
the same.

## Credentials

HTTP Basic against NZBGet's ControlUsername/ControlPassword. The config path is
passed to the helpers through the environment rather than argv, so credentials
never appear in `ps` for other users on the box.

The plugin has no state directory and no cache: it reads its config and writes
nothing.

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
