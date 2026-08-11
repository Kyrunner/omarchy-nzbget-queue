// Owns the poll, the parsed state, and the pause/resume/limit commands.
// Knows nothing about how any of it is drawn.
import QtQuick
import Quickshell
import Quickshell.Io

Item {
  id: svc

  property int refreshIntervalSec: 3
  readonly property string pluginDir: Qt.resolvedUrl(".").toString().replace("file://", "")

  // ---- state the widgets read ----
  property bool ok: false
  property string error: "starting"
  property string barText: ""
  property string rateText: "0 B/s"
  property string etaText: ""
  property string remainingText: ""
  property string freeDiskText: ""
  property int limitKbps: 0
  property string endpoint: ""
  property bool paused: false
  property int postJobs: 0
  property var items: []
  property bool stale: false

  property string busyAction: ""
  property string actionError: ""

  readonly property int count: items ? items.length : 0
  readonly property bool idle: ok && barText === ""
  readonly property string summary: {
    if (!ok) return error
    if (idle) return "nothing downloading"
    if (paused) return "paused · " + count + (count === 1 ? " item" : " items")
    return rateText + " · " + count + (count === 1 ? " item" : " items")
  }

  Process {
    id: poll
    command: ["bash", svc.pluginDir + "/backend.sh"]
    running: false
    stdout: StdioCollector {
      onStreamFinished: {
        var raw = this.text ? this.text.trim() : ""
        if (raw === "") { svc.stale = svc.count > 0; svc.ok = false; svc.error = "no output"; return }
        try {
          var d = JSON.parse(raw)
          svc.ok = !!d.ok
          svc.error = d.error ? String(d.error) : ""
          if (d.ok) {
            svc.barText = d.bar_text || ""
            svc.rateText = d.rate_text || "0 B/s"
            svc.etaText = d.eta_text || ""
            svc.remainingText = d.remaining_text || ""
            svc.freeDiskText = d.free_disk_text || ""
            svc.limitKbps = d.limit_kbps || 0
            svc.endpoint = d.endpoint || ""
            svc.paused = !!d.paused
            svc.postJobs = d.post_jobs || 0
            svc.items = d.items || []
            svc.stale = false
          } else {
            svc.stale = svc.count > 0
          }
        } catch (e) {
          svc.ok = false; svc.error = "unparseable"; svc.stale = svc.count > 0
        }
      }
    }
  }

  Process {
    id: action
    running: false
    stdout: StdioCollector {
      onStreamFinished: {
        var raw = this.text ? this.text.trim() : ""
        var good = false, msg = "failed"
        try { var d = JSON.parse(raw); good = !!d.ok; msg = d.error || "failed" } catch (e) {}
        svc.actionError = good ? "" : String(msg)
        svc.busyAction = ""
        svc.refresh()   // NZBGet is the authority on what actually changed
      }
    }
  }

  function refresh() { if (!poll.running) poll.running = true }

  function run(args, label) {
    if (action.running || busyAction !== "") return
    busyAction = label
    actionError = ""
    action.command = ["bash", pluginDir + "/backend.sh"].concat(args)
    action.running = true
  }

  function pause()  { run(["pause"], "pause") }
  function resume() { run(["resume"], "resume") }
  function setLimit(kbps) { run(["limit", String(kbps)], "limit") }

  Timer {
    // A speed readout needs a few seconds to feel live, but an idle NZBGet does
    // not deserve a wakeup every 3s on a laptop. Nothing in the queue means
    // nothing worth watching closely.
    interval: (svc.idle ? 15 : Math.max(2, svc.refreshIntervalSec)) * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: svc.refresh()
  }
}
