import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// Read-only view of what the daemon wrote. The daemon removes status.json when
// it stops, so an absent file is a stopped daemon rather than a quiet one --
// the same convention the AirPods plugin uses.
Item {
  id: root

  property var settings: ({})

  property bool daemonRunning: false
  property bool connected: false
  property string lastError: ""
  property string deviceName: ""
  property var messages: []
  property bool schemaUnsupported: false
  property int lastSeenId: 0
  property string actionStatus: ""

  readonly property string stateHome: (Quickshell.env("XDG_STATE_HOME")
    || Quickshell.env("HOME") + "/.local/state") + "/pushover"
  readonly property string statePath: stateHome + "/status.json"
  // The daemon never reads this file. Unread is a property of this screen
  // having been looked at, which only the widget can know.
  readonly property string lastSeenPath: stateHome + "/last-seen"

  readonly property int unread: Model.unreadCount(messages, lastSeenId)
  readonly property bool hasMessages: messages.length > 0

  function refresh() {
    stateFile.reload()
    lastSeenFile.reload()
  }

  function markAllRead() {
    var highest = Model.highestId(messages)
    if (highest <= lastSeenId) return
    lastSeenId = highest
    markReadProcess.command = ["sh", "-c",
      "mkdir -p \"$(dirname \"$1\")\" && printf '%s' \"$2\" > \"$1\"",
      "sh", lastSeenPath, String(highest)]
    markReadProcess.running = true
  }

  function acknowledge(receipt) {
    if (!receipt) return
    actionStatus = "Acknowledging…"
    ackProcess.command = ["pushover-open-client", "ack", String(receipt)]
    ackProcess.running = true
  }

  function openUrl(url) {
    if (!url) return
    openProcess.command = ["xdg-open", String(url)]
    openProcess.running = true
  }

  function applyState(raw) {
    var status = Model.parseStatus(raw)
    if (!status.ok) {
      // An unreadable file still proves the daemon is running and writing.
      daemonRunning = true
      connected = false
      schemaUnsupported = status.schemaTooNew
      lastError = status.lastError
      return
    }
    daemonRunning = true
    schemaUnsupported = false
    connected = status.connected
    lastError = status.lastError
    deviceName = status.deviceName
    messages = status.messages
  }

  function stateGone() {
    daemonRunning = false
    connected = false
    schemaUnsupported = false
    lastError = ""
    messages = []
  }

  FileView {
    id: stateFile
    path: root.statePath
    watchChanges: true
    printErrors: false
    // text() is stale inside the change signal, so both paths go through reload.
    onFileChanged: reload()
    onLoaded: root.applyState(text())
    onLoadFailed: root.stateGone()
  }

  FileView {
    id: lastSeenFile
    path: root.lastSeenPath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      var parsed = parseInt(String(text()).trim(), 10)
      root.lastSeenId = isNaN(parsed) ? 0 : parsed
    }
    // No marker yet means nothing has been read, which is the correct start.
    onLoadFailed: root.lastSeenId = 0
  }

  Process { id: markReadProcess }
  Process { id: openProcess }

  Process {
    id: ackProcess
    onExited: function (exitCode) {
      root.actionStatus = exitCode === 0 ? "Acknowledged" : "Could not acknowledge"
      statusClear.restart()
    }
  }

  Timer {
    id: statusClear
    interval: 2500
    onTriggered: root.actionStatus = ""
  }
}
