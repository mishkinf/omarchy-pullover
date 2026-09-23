import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

Panel {
  id: root
  moduleName: "io.github.mishkinf.pullover"
  ipcTarget: "pullover"
  manageIpc: false

  property int cursorIndex: 0
  property bool cursorActive: false
  property int nowSeconds: Math.floor(Date.now() / 1000)
  // Captured before markAllRead runs. `unread` is a binding that goes to zero
  // the instant the panel opens, so reading it per row made the bold-title
  // emphasis permanently unreachable.
  property int unreadOnOpen: 0

  readonly property bool hideWhenIdle: setting("hideWhenIdle", false) === true
  readonly property int maxVisible: {
    var value = Number(setting("maxVisible", 12))
    // NaN from a non-numeric shell.json value would slice to an empty list
    // while the header and Clear button still rendered.
    return isNaN(value) ? 12 : Math.max(1, value)
  }

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // U+F009A bell, U+F009B bell-off, written as surrogate pairs to match the
  // shell's own convention (PolkitAgent.qml). The ES6 \u{...} form parses fine
  // here -- measured byte-identical on quickshell 0.3.1 -- so this is house
  // style, not a workaround. The broken box that prompted it was the icon
  // sizing below, not the escape.
  readonly property string barGlyph: pushover.daemonRunning ? "\udb80\udc9a" : "\udb80\udc9b"
  readonly property color barIconColor: !pushover.daemonRunning
    ? Qt.darker(barForeground, 1.55)
    : (pushover.connected ? barForeground : root.urgent)

  readonly property var visibleMessages: pushover.liveMessages.slice(0, maxVisible)

  visible: !hideWhenIdle || pushover.daemonRunning
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: if (opened) {
    cursorActive = false
    cursorIndex = 0
    if (panelFlick) panelFlick.contentY = 0
    nowSeconds = Math.floor(Date.now() / 1000)
    pushover.refresh()
    unreadOnOpen = pushover.unread
    // Opening the panel is the act of reading, so the badge clears here and
    // not on arrival.
    pushover.markAllRead()
    // A plain Qt.callLater loses: KeyboardPanel schedules its own
    // focusTarget.forceActiveFocus() on the same tick and, being declared
    // after this handler, runs last. The timer lands after both.
    signInFocus.restart()
  }

  function moveCursor(dy) {
    cursorActive = true
    if (visibleMessages.length === 0) return
    cursorIndex = Math.max(0, Math.min(visibleMessages.length - 1, cursorIndex + dy))
  }

  function submitSignIn() {
    if (emailField.text === "" || passwordField.text === "") return
    // Empty means "use the hostname", which the client works out for itself.
    pushover.signIn(emailField.text, passwordField.text, twofaField.text,
                    deviceField.text !== "" ? deviceField.text : pushover.suggestedDeviceName)
  }

  function currentMessage() {
    if (visibleMessages.length === 0) return null
    return visibleMessages[Math.max(0, Math.min(cursorIndex, visibleMessages.length - 1))]
  }

  function activateCursor() {
    var message = currentMessage()
    if (!message) return
    if (message.url !== "") pushover.openUrl(message.url)
    else if (Model.needsAck(message, pushover.ackedIds)) pushover.acknowledge(message.receipt, message.idStr)
  }

  Service {
    id: pushover
    settings: root.settings
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function toggle(): void { root.toggle() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function refresh(): string { pushover.refresh(); return "ok" }
    function unread(): string { return String(pushover.unread) }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    iconComponent: Component {
      Item {
        OpticalGlyph {
          anchors.fill: parent
          text: root.barGlyph
          fontFamily: root.fontFamily
          // The bar's own token, as first-party bar glyphs use. Style.font.icon
          // is a panel token: 1px larger, blind to a theme's bar.icon-font, and
          // it scales differently when barScaleWithFont is off.
          fontSize: button.fontSize
          color: root.barIconColor
        }

        // The count rides the glyph rather than sitting beside it, so the bar
        // does not reflow every time a push lands.
        Rectangle {
          visible: pushover.unread > 0
          anchors.right: parent.right
          anchors.top: parent.top
          anchors.rightMargin: -Style.space(2)
          anchors.topMargin: -Style.space(1)
          implicitWidth: Math.max(badgeText.implicitWidth + Style.space(4), Style.space(10))
          implicitHeight: Style.space(10)
          radius: height / 2
          color: root.urgent

          Text {
            id: badgeText
            textFormat: Text.PlainText
            anchors.centerIn: parent
            text: pushover.unread > 9 ? "9+" : String(pushover.unread)
            color: Color.background
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }
      }
    }
    onPressed: function (buttonCode) {
      if (buttonCode === Qt.RightButton) pushover.refresh()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(420))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(560))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      // Documented contract of PanelKeyCatcher: a panel with an inline editor
      // must block it, or "j" scrolls the list instead of typing a letter.
      blocked: emailField.activeFocus || passwordField.activeFocus
        || twofaField.activeFocus || deviceField.activeFocus
      onMoveRequested: function (dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        if (dy !== 0) root.moveCursor(dy)
      }
      // No cursorActive guard: `o` already acts on the first message without
      // one, and Enter doing nothing until you press j once is a wart, not a
      // feature.
      onActivateRequested: root.activateCursor()
      onCloseRequested: root.close()
      onTabRequested: function (direction) { root.switchPanel(direction) }
      onTextKey: function (t) {
        var key = String(t).toLowerCase()
        // Before the built-in keys, because an unconfigured install has none of
        // these and a configured one cannot reach the reserved letters anyway
        // (Model.handlerActions drops them).
        var row = root.currentMessage()
        if (row) {
          var offered = Model.actionsFor(row, pushover.handlers)
          for (var i = 0; i < offered.length; i++) {
            if (offered[i].key === key) {
              pushover.runAction(row.idStr, key)
              return
            }
          }
        }
        if (key === "r") pushover.refresh()
        else if (key === "o") {
          var message = root.currentMessage()
          if (message && message.url !== "") pushover.openUrl(message.url)
        } else if (key === "a") {
          var target = root.currentMessage()
          if (target && Model.needsAck(target, pushover.ackedIds)) pushover.acknowledge(target.receipt, target.idStr)
        } else if (key === "d") {
          var going = root.currentMessage()
          if (going) {
            pushover.dismiss(going.idStr)
            // The list shortens under the cursor, so it has to be pulled back
            // or it points past the end.
            root.cursorIndex = Math.max(0, Math.min(root.cursorIndex, root.visibleMessages.length - 1))
          }
        }
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(12)

          PanelHero {
            width: parent.width
            title: "Pullover"
            meta: !pushover.loggedIn && pushover.probed ? "Not signed in"
              : pushover.schemaUnsupported ? "Unsupported status schema"
              : pushover.connected ? (pushover.deviceName !== "" ? "Connected as " + pushover.deviceName : "Connected")
              : !pushover.daemonRunning ? "Client is stopped"
              : "Reconnecting…"
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconOpacity: pushover.connected ? 1.0 : 0.5
            iconComponent: Component {
              // A plain Text rather than OpticalGlyph: the hero's Loader sizes
              // to the child's implicit size, and letting the glyph's own
              // metrics be that size is the only way it cannot come out clipped.
              Item {
                // A nerd-font icon's ink is wider than its one-cell advance, so
                // sizing the box to the text's implicit width cuts the glyph in
                // half. The box is given the room and the glyph is centred in it.
                implicitWidth: Math.round(Style.font.displayLarge * 1.6)
                implicitHeight: Math.round(Style.font.displayLarge * 1.4)

                Text {
                  id: heroGlyph
                  textFormat: Text.PlainText
                  anchors.fill: parent
                  horizontalAlignment: Text.AlignHCenter
                  verticalAlignment: Text.AlignVCenter
                  text: root.barGlyph
                  color: pushover.connected ? root.foreground : root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.displayLarge
                }
              }
            }
          }

          Text {
            textFormat: Text.PlainText
            // An action result gets its own field, or the next state read wipes it unread.
            visible: pushover.actionStatus !== "" || pushover.lastError !== ""
            width: parent.width
            text: pushover.actionStatus !== "" ? pushover.actionStatus : pushover.lastError
            color: root.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          Column {
            visible: pushover.trialEndingSoon
            width: parent.width
            spacing: Style.space(6)

            Text {
              textFormat: Text.PlainText
              width: parent.width
              text: pushover.trialDaysRemaining <= 0
                ? "The Pushover desktop trial has ended. This device may have stopped receiving."
                : "Pushover desktop trial ends in " + pushover.trialDaysRemaining
                  + (pushover.trialDaysRemaining === 1 ? " day." : " days.")
                  + " After that this device stops receiving."
              color: root.urgent
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }

            Row {
              width: parent.width
              spacing: Style.space(6)

              Button {
                bordered: true
                foreground: root.foreground
                fontFamily: root.fontFamily
                fontSize: Style.font.caption
                text: "Buy the $4.99 licence"
                onClicked: pushover.openUrl("https://pushover.net/clients/desktop")
              }

              Button {
                bordered: true
                foreground: root.dim
                fontFamily: root.fontFamily
                fontSize: Style.font.caption
                // Pushover exposes no way to read licence status, so the only
                // source for "already paid" is the person who paid.
                text: "Already bought it"
                onClicked: pushover.markLicensed()
              }
            }
          }

          Text {
            textFormat: Text.PlainText
            visible: pushover.clientMissing
            width: parent.width
            text: "The client is not installed. Run ./setup in the plugin folder:\n~/.config/omarchy/plugins/io.github.mishkinf.pullover"
            color: root.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          // Signing in lives here rather than in a terminal: a plugin that
          // needs a CLI before it works has not handled authentication.
          Column {
            id: signInForm
            visible: pushover.probed && !pushover.loggedIn && !pushover.clientMissing
            width: parent.width
            spacing: Style.space(8)

            PanelSectionHeader {
              text: "SIGN IN"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              text: "Sign in to Pushover. Your password is never stored \u2014 it is exchanged for an account session token, kept at mode 600."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            TextField {
              id: emailField
              width: parent.width
              placeholderText: "Email"
              foreground: root.foreground
              enabled: !pushover.signingIn
              onAccepted: passwordField.forceActiveFocus()
            }

            TextField {
              id: passwordField
              width: parent.width
              placeholderText: "Password"
              password: true
              foreground: root.foreground
              enabled: !pushover.signingIn
              onAccepted: root.submitSignIn()
            }

            TextField {
              id: deviceField
              width: parent.width
              placeholderText: pushover.suggestedDeviceName !== ""
                ? "Device name (" + pushover.suggestedDeviceName + ")"
                : "Device name"
              foreground: root.foreground
              enabled: !pushover.signingIn
              onAccepted: root.submitSignIn()
            }

            TextField {
              id: twofaField
              width: parent.width
              // Revealed only once the server has asked for it, so an account
              // without two-factor never sees a field it cannot fill.
              visible: pushover.needsTwofa
              placeholderText: "Two-factor code"
              foreground: root.foreground
              enabled: !pushover.signingIn
              onAccepted: root.submitSignIn()
              onVisibleChanged: if (visible) Qt.callLater(forceActiveFocus)
            }

            Text {
              textFormat: Text.PlainText
              visible: pushover.loginError !== ""
              width: parent.width
              text: pushover.loginError
              color: root.urgent
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }

            Button {
              width: parent.width
              bordered: true
              foreground: root.foreground
              fontFamily: root.fontFamily
              text: pushover.signingIn ? "Signing in…" : "Sign in"
              enabled: !pushover.signingIn && emailField.text !== "" && passwordField.text !== ""
              onClicked: root.submitSignIn()
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              text: "Pushover for Desktop is free for 30 days, then a one-time $4.99 licence on your account."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }
          }

          // Signed in, but nothing is holding the socket.
          Column {
            visible: pushover.loggedIn && !pushover.serviceActive && pushover.probed && !pushover.clientMissing
            width: parent.width
            spacing: Style.space(8)

            Text {
              textFormat: Text.PlainText
              width: parent.width
              text: "Signed in as " + (pushover.deviceName || "this machine") + ", but the client is not running, so nothing is arriving."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }

            Button {
              width: parent.width
              bordered: true
              foreground: root.foreground
              fontFamily: root.fontFamily
              text: "Start receiving"
              onClicked: pushover.startService()
            }
          }

          Column {
            visible: pushover.hasMessages
            width: parent.width
            spacing: Style.space(10)

            Item {
              width: parent.width
              implicitHeight: recentHeader.implicitHeight

              PanelSectionHeader {
                id: recentHeader
                anchors.left: parent.left
                text: "RECENT"
                foreground: root.foreground
                fontFamily: root.fontFamily
              }

              Button {
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                foreground: root.dim
                fontFamily: root.fontFamily
                fontSize: Style.font.caption
                text: "Clear"
                onClicked: pushover.dismissAll()
              }
            }

            Column {
              width: parent.width
              spacing: Style.space(4)

              Repeater {
                model: root.visibleMessages
                MessageRow {
                  required property var modelData
                  required property int index
                  width: parent.width
                  message: modelData
                  rowIndex: index
                }
              }
            }
          }

          PanelSeparator {
            visible: pushover.loggedIn
            foreground: root.foreground
          }

          Button {
            visible: pushover.loggedIn
            width: parent.width
            foreground: root.dim
            fontFamily: root.fontFamily
            fontSize: Style.font.caption
            text: "Sign out " + (pushover.deviceName !== "" ? "(" + pushover.deviceName + ")" : "")
            onClicked: pushover.signOut()
          }

          Text {
            textFormat: Text.PlainText
            visible: !pushover.hasMessages && pushover.loggedIn && pushover.serviceActive
            width: parent.width
            text: "No pushes yet. Anything sent to this device will arrive here."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            wrapMode: Text.WordWrap
            horizontalAlignment: Text.AlignHCenter
          }
        }
      }
    }
  }

  // Relative timestamps go stale silently, so they are re-derived while the
  // panel is the thing being looked at.
  Timer {
    id: signInFocus
    interval: 1
    onTriggered: {
      if (pushover.probed && !pushover.loggedIn && !pushover.clientMissing) emailField.forceActiveFocus()
      else keyCatcher.forceActiveFocus()
    }
  }

  // Re-aim once the probe answers, since the first open happens before it does.
  Connections {
    target: pushover
    function onProbedChanged() { if (root.opened) signInFocus.restart() }
  }

  Timer {
    interval: 30000
    running: root.opened
    repeat: true
    onTriggered: root.nowSeconds = Math.floor(Date.now() / 1000)
  }

  component MessageRow: CursorSurface {
    id: messageRow
    property var message: ({})
    property int rowIndex: 0

    readonly property bool emergency: Model.needsAck(message, pushover.ackedIds)
    readonly property var actions: Model.actionsFor(message, pushover.handlers)
    readonly property string priorityText: Model.priorityLabel(message.priority || 0)
    // Position, not id: see the note on unreadCount in Model.js. Against the
    // count captured at open, not the live one, which is already zero by now.
    readonly property bool unread: rowIndex < root.unreadOnOpen

    hasCursor: root.cursorActive && root.cursorIndex === rowIndex
    foreground: root.foreground
    implicitHeight: rowContent.implicitHeight + Style.spacing.rowPaddingX

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onEntered: { root.cursorActive = true; root.cursorIndex = messageRow.rowIndex }
      onClicked: root.activateCursor()
    }

    ColumnLayout {
      id: rowContent
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      spacing: Style.space(2)

      RowLayout {
        Layout.fillWidth: true
        spacing: Style.space(6)

        Text {
          textFormat: Text.PlainText
          Layout.fillWidth: true
          text: messageRow.message.title || "Pushover"
          color: root.foreground
          opacity: messageRow.unread ? 1.0 : 0.75
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          font.bold: messageRow.unread
          elide: Text.ElideRight
        }

        Text {
          textFormat: Text.PlainText
          visible: messageRow.priorityText !== ""
          text: messageRow.priorityText
          color: messageRow.emergency ? root.urgent : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }

        Text {
          textFormat: Text.PlainText
          text: Model.relativeTime(messageRow.message.date || 0, root.nowSeconds)
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }

      Text {
        textFormat: Text.PlainText
        Layout.fillWidth: true
        text: messageRow.message.message || ""
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        wrapMode: Text.WordWrap
        maximumLineCount: 3
        elide: Text.ElideRight
      }

      Text {
        textFormat: Text.PlainText
        Layout.fillWidth: true
        visible: text !== ""
        text: {
          // An emergency says what the keys are, because acknowledging is the
          // point of it. Everything else shows where Enter goes, and appends
          // whatever extra keys this sender's handler offers.
          var hint = Model.actionHint(messageRow.actions)
          var hasUrl = (messageRow.message.url || "") !== ""
          var base = messageRow.emergency
            ? ((hasUrl ? "Enter to open · " : "") + "a to acknowledge · d to dismiss")
            : (messageRow.message.urlTitle || messageRow.message.url || "")
          if (hint === "") return base
          return base === "" ? hint : base + " · " + hint
        }
        color: messageRow.emergency ? root.urgent : Qt.darker(root.foreground, 2.0)
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }
    }
  }
}
