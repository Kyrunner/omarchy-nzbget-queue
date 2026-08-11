// NZBGet mark plus the live speed, and the host for the queue popout.
//
// Built as a Row rather than with WidgetButton, which takes a label but has no
// icon slot, or BarIconButton, which takes a square icon but hides any label.
// omarchy.media's bar widget does the same thing for the same reason: it needs a
// glyph and a track name side by side.
import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "ky.nzbget-queue"

  readonly property bool hideWhenIdle: (root.settings && root.settings.hideWhenIdle !== undefined)
                                       ? root.settings.hideWhenIdle : true
  readonly property bool idle: nzb.ok && nzb.barText === ""

  // The mark carries the identity, so text is only added when it says something
  // the icon cannot: a rate, a pause, or a fault. Idle needs no words.
  readonly property string label: {
    if (!nzb.ok) return "!"
    return nzb.barText
  }

  readonly property color fg: root.bar ? root.bar.barForeground : Color.foreground
  readonly property color urgent: root.bar ? root.bar.urgent : Color.urgent

  NzbgetService {
    id: nzb
    refreshIntervalSec: (root.settings && root.settings.refreshIntervalSec) ? root.settings.refreshIntervalSec : 3
  }

  // ---- Shape contract for shell.summon/hide/toggle routing: Bar.findPanelWidget
  //      requires open/close/opened on the bar-widget root.
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  function open()        { if (panelLoader.item) panelLoader.item.open() }
  function close()       { if (panelLoader.item) panelLoader.item.close() }
  function togglePanel() { if (panelLoader.item) panelLoader.item.toggle() }

  // Forwarded so this widget can stand in for the panel as the bar's popout
  // identity: Bar.requestPopout prefers closeForPopoutSwitch over close, and
  // KeyboardPanel reads popoutSwitchClosing back off its owner.
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false
  function closeForPopoutSwitch() { if (panelLoader.item) panelLoader.item.closeForPopoutSwitch() }

  readonly property real openPanelIndicatorWidth: row.implicitWidth
  readonly property real openPanelIndicatorHeight: Math.max(Style.space(10), Math.round(Style.bar.iconSlot * 0.55))

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = root
    if ("hostWidget" in target) target.hostWidget = root
    if ("svc" in target) target.svc = nzb
  }

  // Idle collapses to nothing — the honest way to say "no downloads" in a bar
  // already carrying a dozen widgets. A FAULT keeps its width, so broken and
  // idle never look the same.
  visible: !(root.idle && root.hideWhenIdle)
  implicitWidth: (root.idle && root.hideWhenIdle) ? 0 : row.implicitWidth + Style.space(14)
  implicitHeight: root.barSize

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  Row {
    id: row
    anchors.centerIn: parent
    spacing: root.label === "" ? 0 : Style.space(6)

    Image {
      id: mark
      anchors.verticalCenter: parent.verticalCenter
      source: Qt.resolvedUrl("nzbget.svg")
      width: Math.round(Style.bar.iconSlot * 0.62)
      height: width
      // Rasterise above the drawn size so the mark stays crisp on a HiDPI bar.
      sourceSize.width: 48
      sourceSize.height: 48
      fillMode: Image.PreserveAspectFit
      smooth: true
      // Dimmed while paused or faulted: the mark should not look equally alive
      // whether or not anything is moving.
      opacity: !nzb.ok ? 0.5 : (nzb.paused ? 0.55 : 1.0)
    }

    Text {
      id: labelText
      anchors.verticalCenter: parent.verticalCenter
      visible: root.label !== ""
      text: root.label
      color: nzb.ok ? (nzb.paused ? Qt.darker(root.fg, 1.5) : root.fg) : root.urgent
      font.family: root.bar ? root.bar.fontFamily : Style.font.family
      font.pixelSize: Style.font.body
      renderType: Text.NativeRendering
      Behavior on color {
        enabled: !root.bar || root.bar.foregroundAnimationEnabled
        ColorAnimation { duration: 160 }
      }
    }
  }

  MouseArea {
    anchors.fill: parent
    hoverEnabled: true
    acceptedButtons: Qt.LeftButton | Qt.MiddleButton
    cursorShape: Qt.PointingHandCursor
    onClicked: function(mouse) {
      if (mouse.button === Qt.MiddleButton) nzb.refresh()
      else root.togglePanel()
    }
  }
}
