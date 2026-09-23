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
  property string lastSeenIdStr: ""
  property var dismissedIds: []
  property var ackedIds: []
  property var trial: ({})
  property string actionStatus: ""

  // Sign-in state. The daemon cannot report this -- it is not running until
  // there is a login -- so it is probed from the credentials file instead.
  property bool probed: false
  property bool loggedIn: false
  property bool serviceActive: false
  property bool serviceEnabled: false
  property bool signingIn: false
  property bool needsTwofa: false
  property string loginError: ""
  property string suggestedDeviceName: ""
  // The plugin can be enabled without ./setup having been run, in which case
  // the CLI is not on PATH. That is a different problem from being signed out
  // and needs a different answer.
  property bool clientMissing: false

  readonly property string stateHome: (Quickshell.env("XDG_STATE_HOME")
    || Quickshell.env("HOME") + "/.local/state") + "/pullover"
  readonly property string statePath: stateHome + "/status.json"
  // The daemon never reads this file. Unread is a property of this screen
  // having been looked at, which only the widget can know.
  readonly property string lastSeenPath: stateHome + "/last-seen"
  readonly property string dismissedPath: stateHome + "/dismissed"
  readonly property string ackedPath: stateHome + "/acked"

  readonly property var liveMessages: Model.liveMessages(messages, dismissedIds)
  readonly property int unread: Model.unreadCount(messages, lastSeenIdStr, dismissedIds)
  readonly property bool hasMessages: liveMessages.length > 0

  readonly property bool trialKnown: trial && trial.known === true && trial.licensed !== true
  readonly property int trialDaysRemaining: trialKnown ? Number(trial.daysRemaining || 0) : -1
  // Seven days is when it stops being trivia and starts being a deadline.
  readonly property bool trialEndingSoon: trialKnown && trialDaysRemaining <= 7

  function refresh() {
    stateFile.reload()
    // The read marker is deliberately NOT reloaded here. It is watched, and a
    // reload racing markAllRead's write returns the pre-write content and
    // silently un-reads everything the user just looked at.
    probe()
  }

  function probe() {
    if (probeProcess.running) return
    probeProcess.running = true
  }

  // The password goes over stdin, never argv: anything in argv is readable by
  // every other process on this machine.
  function signIn(email, password, twofa, deviceName) {
    if (signingIn) return
    loginError = ""
    signingIn = true
    loginProcess.request = JSON.stringify({
      email: String(email || ""),
      password: String(password || ""),
      twofa: String(twofa || ""),
      deviceName: String(deviceName || "omarchy")
    })
    loginProcess.running = true
  }

  function startService() {
    if (serviceProcess.running) return
    actionStatus = "Starting…"
    serviceProcess.command = ["pullover", "service", "enable"]
    serviceProcess.running = true
  }

  function signOut() {
    if (serviceProcess.running) return
    actionStatus = "Signing out…"
    serviceProcess.command = ["pullover", "logout"]
    serviceProcess.running = true
  }

  function dismiss(idStr) {
    if (!idStr || Model.isDismissed(idStr, dismissedIds)) return
    var next = dismissedIds.slice()
    next.push(String(idStr))
    _writeDismissed(Model.prunedDismissed(messages, next))
  }

  function dismissAll() {
    var next = []
    for (var i = 0; i < messages.length; i++) next.push(messages[i].idStr)
    _writeDismissed(next)
  }

  function _writeDismissed(list) {
    dismissedIds = list
    _write(dismissedPath, list, dismissedProcess)
  }

  function _write(path, list, process) {
    process.command = ["sh", "-c",
      "mkdir -p \"$(dirname \"$1\")\" && printf '%s' \"$2\" > \"$1\"",
      "sh", path, list.join("\n")]
    process.running = true
  }

  // These are set optimistically before the write, so a silent failure would
  // leave memory and disk disagreeing until the next shell restart.
  function writeFailed(what) {
    actionStatus = "Could not save " + what + "."
    statusClear.restart()
  }

  function markLicensed() {
    if (serviceProcess.running) return
    actionStatus = "Saved — the countdown stops."
    serviceProcess.command = ["pullover", "licensed"]
    serviceProcess.running = true
  }

  function markAllRead() {
    var newest = Model.newestIdStr(messages)
    if (newest === "" || newest === lastSeenIdStr) return
    lastSeenIdStr = newest
    markReadProcess.command = ["sh", "-c",
      "mkdir -p \"$(dirname \"$1\")\" && printf '%s' \"$2\" > \"$1\"",
      "sh", lastSeenPath, newest]
    markReadProcess.running = true
  }

  function acknowledge(receipt, idStr) {
    if (!receipt || ackProcess.running) return
    actionStatus = "Acknowledging…"
    ackProcess.pendingId = String(idStr || "")
    ackProcess.command = ["pullover", "ack", String(receipt)]
    ackProcess.running = true
  }

  // The daemon gates the identical value before handing it to xdg-open
  // (url_is_openable in bin/pullover). Same data, same program: gate it here
  // too, or a push carrying file:// is one Enter away from opening it.
  function openUrl(url) {
    var target = String(url || "")
    if (!Model.isOpenableUrl(target)) {
      actionStatus = "That link is not an http(s) address."
      statusClear.restart()
      return
    }
    openProcess.command = ["xdg-open", target]
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
    daemonRunning = status.running
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
    onLoaded: root.lastSeenIdStr = String(text()).trim()
    // No marker yet means nothing has been read, which is the correct start.
    onLoadFailed: root.lastSeenIdStr = ""
  }

  Process {
    id: markReadProcess
    onExited: function (code) { if (code !== 0) root.writeFailed("the read marker") }
  }

  Process {
    id: dismissedProcess
    onExited: function (code) { if (code !== 0) root.writeFailed("dismissals") }
  }

  FileView {
    id: dismissedFile
    path: root.dismissedPath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      var body = String(text()).trim()
      root.dismissedIds = body === "" ? [] : body.split("\n")
    }
    onLoadFailed: root.dismissedIds = []
  }
  Process { id: openProcess }

  Process {
    id: probeProcess
    command: ["pullover", "probe"]
    stdout: StdioCollector { id: probeOut; waitForEnd: true }
    onExited: function (exitCode) {
      root.probed = true
      var raw = String(probeOut.text || "")
      if (exitCode !== 0 && raw.trim() === "") {
        // Nothing on stdout and a non-zero exit is what a missing command
        // looks like; a probe that ran would have answered in JSON.
        root.clientMissing = true
        return
      }
      root.clientMissing = false
      if (exitCode !== 0) return
      try {
        var data = JSON.parse(raw || "{}")
        root.loggedIn = data.loggedIn === true
        if (data.deviceName) root.deviceName = String(data.deviceName)
        if (data.suggestedDeviceName) root.suggestedDeviceName = String(data.suggestedDeviceName)
        root.trial = data.trial || ({})
        root.serviceActive = data.service && data.service.active === true
        root.serviceEnabled = data.service && data.service.enabled === true
      } catch (error) {
        // A probe we cannot parse says nothing; it must not read as a logout.
      }
    }
  }

  Process {
    id: loginProcess
    property string request: ""
    command: ["pullover", "login", "--stdin"]
    stdinEnabled: true
    stdout: StdioCollector { id: loginOut; waitForEnd: true }
    onStarted: {
      // The newline is what ends the request; the CLI reads one line rather
      // than to EOF, so this cannot depend on the pipe being closed for us.
      write(request + "\n")
      request = ""
      stdinEnabled = false
    }
    onExited: function (exitCode) {
      root.signingIn = false
      var result = {}
      try {
        result = JSON.parse(String(loginOut.text || "{}"))
      } catch (error) {
        root.loginError = "The login command returned something unreadable."
        return
      }
      root.needsTwofa = result.needsTwofa === true
      if (result.ok === true) {
        root.loginError = ""
        root.loggedIn = true
        if (result.deviceName) root.deviceName = String(result.deviceName)
        // Signing in and then not receiving anything would be a strange
        // success, so the client is started as part of it.
        root.startService()
      } else {
        root.loginError = String(result.error || "Login failed")
      }
    }
  }

  Process {
    id: serviceProcess
    onExited: function (exitCode) {
      root.actionStatus = exitCode === 0 ? "" : "Could not start the client"
      if (exitCode !== 0) statusClear.restart()
      root.probe()
    }
  }

  Process {
    id: ackProcess
    property string pendingId: ""
    onExited: function (exitCode) {
      root.actionStatus = exitCode === 0 ? "Acknowledged" : "Could not acknowledge"
      if (exitCode === 0 && pendingId !== "" && !Model.isDismissed(pendingId, root.ackedIds)) {
        var next = root.ackedIds.slice()
        next.push(pendingId)
        root.ackedIds = next
        root._write(root.ackedPath, Model.prunedDismissed(root.messages, next), ackedProcess)
      }
      pendingId = ""
      statusClear.restart()
    }
  }

  FileView {
    id: ackedFile
    path: root.ackedPath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      var body = String(text()).trim()
      root.ackedIds = body === "" ? [] : body.split("\n")
    }
    onLoadFailed: root.ackedIds = []
  }

  Process {
    id: ackedProcess
    onExited: function (code) { if (code !== 0) root.writeFailed("acknowledgements") }
  }

  Timer {
    id: statusClear
    interval: 2500
    onTriggered: root.actionStatus = ""
  }
}
