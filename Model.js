.pragma library

// The daemon owns status.json. Everything here is read-only interpretation of
// it, so a file written by a newer daemon degrades to "cannot read" rather
// than to a confident wrong answer.

var SCHEMA_VERSION = 1

function parseStatus(raw) {
  var blank = {
    ok: false,
    schemaTooNew: false,
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
      id: Number(m.id || 0),
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
function needsAck(message) {
  return message.priority >= 2 && message.receipt !== "" && !message.acked
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
function unreadCount(messages, lastSeenIdStr) {
  if (!lastSeenIdStr) return messages.length
  for (var i = 0; i < messages.length; i++) {
    if (messages[i].idStr === lastSeenIdStr) return i
  }
  // The marked message has aged out of the window, so everything held is new.
  return messages.length
}

function newestIdStr(messages) {
  return messages.length > 0 ? messages[0].idStr : ""
}
