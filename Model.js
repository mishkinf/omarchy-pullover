.pragma library

// The daemon owns status.json. Everything here is read-only interpretation of
// it, so a file written by a newer daemon degrades to "cannot read" rather
// than to a confident wrong answer.

var SCHEMA_VERSION = 1

function parseStatus(raw) {
  var blank = {
    ok: false,
    schemaTooNew: false,
    running: true,
    connected: false,
    lastError: "",
    deviceName: "",
    updatedAt: 0,
    messages: []
  }

  if (!raw || String(raw).trim() === "") return blank

  var data
  try {
    data = JSON.parse(raw)
  } catch (error) {
    return blank
  }

  // An array is typeof "object" too, and a status file holding one is not a
  // status file. Anything that is not a plain object reads as blank.
  if (typeof data !== "object" || data === null || Array.isArray(data)) return blank

  var version = Number(data.schemaVersion || 0)
  if (version > SCHEMA_VERSION) {
    blank.schemaTooNew = true
    blank.lastError = "Status file is newer than this widget. Update the plugin."
    return blank
  }

  return {
    ok: true,
    schemaTooNew: false,
    // Absent means running: a file written before this flag existed was only
    // ever written by a live daemon.
    running: data.running !== false,
    connected: data.connected === true,
    lastError: String(data.lastError || ""),
    deviceName: String(data.deviceName || ""),
    updatedAt: Number(data.updatedAt || 0),
    messages: normalizeMessages(data.messages)
  }
}

function normalizeMessages(list) {
  if (!Array.isArray(list)) return []
  var out = []
  for (var i = 0; i < list.length; i++) {
    var m = list[i]
    if (!m || typeof m !== "object") continue
    out.push({
      // No numeric `id` field: nothing reads it, and Number() on a 19-digit id
      // is precisely the rounding this whole file exists to avoid. The string
      // is the identity. The `|| m.id` fallback covers a status file written
      // before idStr existed; the daemon backfills those on load.
      idStr: String(m.idStr || m.id || ""),
      title: String(m.title || m.app || "Pushover"),
      message: String(m.message || ""),
      app: String(m.app || "Pushover"),
      date: Number(m.date || 0),
      priority: Number(m.priority || 0),
      url: String(m.url || ""),
      urlTitle: String(m.urlTitle || ""),
      receipt: String(m.receipt || ""),
      acked: m.acked === true
    })
  }
  return out
}

// Emergency pushes that nobody has acknowledged are the only ones the panel
// offers an action for, so the test is named rather than inlined twice.
function needsAck(message, acked) {
  if (!message || message.priority < 2 || !message.receipt || message.acked) return false
  // The server never tells us again: the message is deleted from our queue
  // after the sync, so `acked` in status.json can only ever be what it was on
  // arrival. Acknowledgement is therefore remembered here, like dismissal.
  return !isDismissed(message.idStr, acked)
}

function priorityLabel(priority) {
  if (priority >= 2) return "Emergency"
  if (priority === 1) return "High"
  if (priority === -1) return "Quiet"
  if (priority <= -2) return "Lowest"
  return ""
}

function relativeTime(epochSeconds, nowSeconds) {
  if (!epochSeconds) return ""
  var delta = Math.max(0, Math.floor(nowSeconds - epochSeconds))
  if (delta < 45) return "just now"
  if (delta < 3600) return Math.round(delta / 60) + "m ago"
  if (delta < 86400) return Math.round(delta / 3600) + "h ago"
  if (delta < 604800) return Math.round(delta / 86400) + "d ago"
  return new Date(epochSeconds * 1000).toLocaleDateString(Qt.locale(), "d MMM")
}

// Messages arrive newest-first, so "unread" is how many sit above the last one
// that was read. This is deliberately a POSITION and an exact string match
// rather than an id comparison: a Pushover id is 19 digits, JSON.parse turns it
// into a double, and two ids that differ only in their final digits round to
// the same value. Nothing here ever compares two ids as numbers.
function unreadCount(messages, lastSeenIdStr, dismissed) {
  var count = 0
  for (var i = 0; i < messages.length; i++) {
    // The marker is kept against the FULL list, so dismissing the message that
    // happens to be the marker does not re-unread everything above it.
    if (lastSeenIdStr && messages[i].idStr === lastSeenIdStr) return count
    if (!isDismissed(messages[i].idStr, dismissed)) count++
  }
  // The marked message aged out of the window, so everything held is new.
  return count
}

// Mirrors url_is_openable in bin/pullover. xdg-open dispatches any registered
// scheme, and a push is attacker-influenced.
function isOpenableUrl(url) {
  var text = String(url || "")
  return text.indexOf("https://") === 0 || text.indexOf("http://") === 0
}

function isDismissed(idStr, dismissed) {
  return !!dismissed && dismissed.indexOf(idStr) >= 0
}

// Dismissal is the widget's own idea, like unread: the daemon keeps what
// arrived, and this screen decides what is still worth showing.
function liveMessages(messages, dismissed) {
  if (!dismissed || dismissed.length === 0) return messages
  var out = []
  for (var i = 0; i < messages.length; i++) {
    if (!isDismissed(messages[i].idStr, dismissed)) out.push(messages[i])
  }
  return out
}

// Written back after every change so the file cannot grow without bound as
// messages age out of the daemon's window.
//
// An EMPTY message list prunes nothing. The daemon's history is briefly empty
// while it restarts, and pruning against it would throw away every dismissal
// the user has ever made -- including the one being added in the same call.
function prunedDismissed(messages, dismissed) {
  if (!dismissed) return []
  if (!messages || messages.length === 0) return dismissed.slice()
  var known = {}
  for (var i = 0; i < messages.length; i++) known[messages[i].idStr] = true
  var out = []
  for (var j = 0; j < dismissed.length; j++) {
    if (known[dismissed[j]]) out.push(dismissed[j])
  }
  return out
}

function newestIdStr(messages) {
  return messages.length > 0 ? messages[0].idStr : ""
}
