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

  if (typeof data !== "object" || data === null) return blank

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

function unreadCount(messages, lastSeenId) {
  var count = 0
  for (var i = 0; i < messages.length; i++) {
    if (messages[i].id > lastSeenId) count++
  }
  return count
}

function highestId(messages) {
  var highest = 0
  for (var i = 0; i < messages.length; i++) {
    if (messages[i].id > highest) highest = messages[i].id
  }
  return highest
}
