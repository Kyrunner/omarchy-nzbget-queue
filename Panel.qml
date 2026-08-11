// The queue popout. Presentation only: every value comes from the service that
// BarWidget.qml owns and injects.
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import qs.Commons
import qs.Ui

Panel {
  id: root
  moduleName: "ky.nzbget-queue"
  ipcTarget: "ky.nzbget-queue"
  manageIpc: false

  // Injected by BarWidget.injectPanel(); the clock's Panel.qml takes the same
  // pair, and Bar routing needs hostWidget to stand in as the popout identity.
  property var anchorItem: null
  property var hostWidget: null
  property var svc: null

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  // `bar` carries foreground/urgent/fontFamily but NOT background or accent —
  // reading those off it yields undefined, which QML paints black and reports
  // only as a runtime warning.
  readonly property color background: Color.bar.background
  readonly property color accent: Color.accent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // Presets in KB/s. 0 is unlimited, which is the state to return to and so
  // deserves to be one click away rather than buried in a number field.
  readonly property var limitPresets: [
    { label: "off",     kbps: 0 },
    { label: "10 MB/s", kbps: 10240 },
    { label: "5 MB/s",  kbps: 5120 },
    { label: "1 MB/s",  kbps: 1024 }
  ]

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.hostWidget || root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(440))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(560))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTextKey: function(t) {
        if (t === "r" || t === "R") { if (root.svc) root.svc.refresh() }
        if (t === " " && root.svc) {
          if (root.svc.paused) root.svc.resume(); else root.svc.pause()
        }
      }

      Flickable {
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true

        ColumnLayout {
          id: column
          width: parent.width
          spacing: Style.space(10)

          RowLayout {
            Layout.fillWidth: true
            spacing: Style.space(8)

            // The bar item is a speed label rather than an icon — WidgetButton
            // takes a label OR BarIconButton takes a square icon, never both —
            // so the popup header is where the mark actually gets to appear.
            Image {
              source: Qt.resolvedUrl("nzbget.svg")
              Layout.preferredWidth: Style.space(20)
              Layout.preferredHeight: Style.space(20)
              sourceSize.width: 40
              sourceSize.height: 40
              fillMode: Image.PreserveAspectFit
              smooth: true
            }

            Text {
              Layout.fillWidth: true
              text: "NZBGet"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
            }
            // Worth stating rather than leaving a mystery: on the public path
            // the widget is reaching NZBGet from outside the LAN.
            Text {
              visible: !!root.svc && root.svc.endpoint === "public"
              text: "remote"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            Text {
              visible: !!root.svc && root.svc.ok
              text: root.svc ? root.svc.freeDiskText + " free" : ""
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }

          Text {
            Layout.fillWidth: true
            visible: !!root.svc && root.svc.faulted
            text: root.svc ? ("Not available — " + root.svc.error
                              + (root.svc.stale ? " (showing last known)" : "")) : ""
            color: root.urgent
            font.family: root.fontFamily
            wrapMode: Text.WordWrap
          }

          Text {
            Layout.fillWidth: true
            visible: !!root.svc && root.svc.faulted && root.svc.error === "not configured"
            text: "Create ~/.config/omarchy-nzbget/config.json with url, user and password."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          // Overall line: rate, what is left, and when it will be done.
          Text {
            Layout.fillWidth: true
            visible: !!root.svc && root.svc.ok && root.svc.count > 0
            text: {
              if (!root.svc) return ""
              var s = root.svc.paused ? "Paused" : root.svc.rateText
              if (root.svc.remainingText) s += " · " + root.svc.remainingText + " left"
              if (root.svc.etaText) s += " · " + root.svc.etaText
              return s
            }
            color: root.foreground
            font.family: root.fontFamily
          }

          Text {
            Layout.fillWidth: true
            visible: !!root.svc && root.svc.ok && root.svc.count === 0
            text: "Nothing downloading."
            color: root.dim
            font.family: root.fontFamily
          }

          Text {
            Layout.fillWidth: true
            visible: !!root.svc && root.svc.actionError !== ""
            text: root.svc ? ("Command failed — " + root.svc.actionError) : ""
            color: root.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          Repeater {
            model: root.svc ? root.svc.items : []
            delegate: ColumnLayout {
              required property var modelData
              Layout.fillWidth: true
              spacing: Style.space(3)

              Text {
                Layout.fillWidth: true
                text: modelData.name
                color: root.foreground
                font.family: root.fontFamily
                font.bold: modelData.active
                elide: Text.ElideRight
              }

              Rectangle {
                Layout.fillWidth: true
                height: Style.space(4)
                radius: height / 2
                color: Qt.darker(root.foreground, 3.0)
                Rectangle {
                  height: parent.height
                  radius: parent.radius
                  width: parent.width * (modelData.percent / 100)
                  color: modelData.paused ? root.dim
                         : (modelData.active ? root.accent : Qt.darker(root.accent, 1.7))
                  Behavior on width { NumberAnimation { duration: 400; easing.type: Easing.OutCubic } }
                }
              }

              Text {
                Layout.fillWidth: true
                text: {
                  var s = modelData.percent + "% · " + modelData.done_text + " / " + modelData.size_text
                  s += " · " + modelData.status
                  if (modelData.eta_text) s += " · " + modelData.eta_text + " left"
                  if (modelData.category) s += " · " + modelData.category
                  return s
                }
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
              }
            }
          }

          PanelSeparator { Layout.fillWidth: true; visible: !!root.svc && root.svc.ok }

          RowLayout {
            Layout.fillWidth: true
            visible: !!root.svc && root.svc.ok
            spacing: Style.space(8)

            PanelActionButton {
              iconText: (root.svc && root.svc.paused) ? "󰐊" : "󰏤"
              tooltipText: (root.svc && root.svc.paused) ? "Resume downloading" : "Pause downloading"
              foreground: root.foreground
              hoverColor: root.accent
              enabled: !!root.svc && root.svc.busyAction === ""
              onClicked: { if (root.svc.paused) root.svc.resume(); else root.svc.pause() }
            }

            Text {
              text: (root.svc && root.svc.busyAction !== "") ? "working…" : ""
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            Item { Layout.fillWidth: true }

            Text {
              text: "limit"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            Repeater {
              model: root.limitPresets
              delegate: Rectangle {
                required property var modelData
                readonly property bool current: !!root.svc && root.svc.limitKbps === modelData.kbps
                implicitWidth: presetText.implicitWidth + Style.space(12)
                implicitHeight: presetText.implicitHeight + Style.space(6)
                radius: Style.space(4)
                color: current ? root.accent : "transparent"
                border.width: 1
                border.color: current ? root.accent : Qt.darker(root.foreground, 2.4)

                Text {
                  id: presetText
                  anchors.centerIn: parent
                  text: modelData.label
                  color: parent.current ? root.background : root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }

                MouseArea {
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  enabled: !!root.svc && root.svc.busyAction === ""
                  onClicked: root.svc.setLimit(modelData.kbps)
                }
              }
            }
          }
        }
      }
    }
  }
}
