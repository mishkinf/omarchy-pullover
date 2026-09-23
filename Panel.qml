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
  moduleName: "io.github.mishkinf.pushover"
  ipcTarget: "pushover"
  manageIpc: false

  property int cursorIndex: 0
  property bool cursorActive: false
  property int nowSeconds: Math.floor(Date.now() / 1000)

  readonly property bool hideWhenIdle: setting("hideWhenIdle", false) === true
  readonly property int maxVisible: Math.max(1, Number(setting("maxVisible", 12)))

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // Surrogate pairs, not \u{...}: the shell's QML does not parse the ES6 form,
  // and an unparsed escape renders as a broken box. U+F009A bell, U+F009B bell-off.
  readonly property string barGlyph: pushover.daemonRunning ? "\udb80\udc9a" : "\udb80\udc9b"
  readonly property color barIconColor: !pushover.daemonRunning
    ? Qt.darker(barForeground, 1.55)
    : (pushover.connected ? barForeground : root.urgent)

  readonly property var visibleMessages: pushover.messages.slice(0, maxVisible)

  visible: !hideWhenIdle || pushover.daemonRunning
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: if (opened) {
    cursorActive = false
    cursorIndex = 0
    if (panelFlick) panelFlick.contentY = 0
    nowSeconds = Math.floor(Date.now() / 1000)
    pushover.refresh()
    // Opening the panel is the act of reading, so the badge clears here and
    // not on arrival.
    pushover.markAllRead()
    Qt.callLater(function () {
      if (pushover.probed && !pushover.loggedIn) emailField.forceActiveFocus()
      else keyCatcher.forceActiveFocus()
    })
  }

  function moveCursor(dy) {
    cursorActive = true
    if (visibleMessages.length === 0) return
    cursorIndex = Math.max(0, Math.min(visibleMessages.length - 1, cursorIndex + dy))
  }

  function submitSignIn() {
    if (emailField.text === "" || passwordField.text === "") return
    pushover.signIn(emailField.text, passwordField.text, twofaField.text, "omarchy")
  }

  function currentMessage() {
    if (visibleMessages.length === 0) return null
    return visibleMessages[Math.max(0, Math.min(cursorIndex, visibleMessages.length - 1))]
  }

  function activateCursor() {
    var message = currentMessage()
    if (!message) return
    if (message.url !== "") pushover.openUrl(message.url)
    else if (Model.needsAck(message)) pushover.acknowledge(message.receipt)
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
          fontSize: Style.font.icon
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
      blocked: emailField.activeFocus || passwordField.activeFocus || twofaField.activeFocus
      onMoveRequested: function (dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        if (dy !== 0) root.moveCursor(dy)
      }
      onActivateRequested: if (root.cursorActive) root.activateCursor()
      onCloseRequested: root.close()
      onTabRequested: function (direction) { root.switchPanel(direction) }
      onTextKey: function (t) {
        var key = String(t).toLowerCase()
        if (key === "r") pushover.refresh()
        else if (key === "o") {
          var message = root.currentMessage()
          if (message && message.url !== "") pushover.openUrl(message.url)
        } else if (key === "a") {
          var target = root.currentMessage()
          if (target && Model.needsAck(target)) pushover.acknowledge(target.receipt)
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
            title: "Pushover"
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

          // Signing in lives here rather than in a terminal: a plugin that
          // needs a CLI before it works has not handled authentication.
          Column {
            id: signInForm
            visible: pushover.probed && !pushover.loggedIn
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
              text: "Your Pushover account. The password is exchanged for a device token and never stored."
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
            visible: pushover.loggedIn && !pushover.serviceActive && pushover.probed
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

            PanelSectionHeader {
              text: "RECENT"
              foreground: root.foreground
              fontFamily: root.fontFamily
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

          Text {
            textFormat: Text.PlainText
            visible: !pushover.hasMessages && pushover.loggedIn && pushover.serviceActive
            width: parent.width
            text: "No pushes yet. Anything sent to your Pushover account will arrive here."
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
    interval: 30000
    running: root.opened
    repeat: true
    onTriggered: root.nowSeconds = Math.floor(Date.now() / 1000)
  }

  component MessageRow: CursorSurface {
    id: messageRow
    property var message: ({})
    property int rowIndex: 0

    readonly property bool emergency: Model.needsAck(message)
    readonly property string priorityText: Model.priorityLabel(message.priority || 0)
    readonly property bool unread: (message.id || 0) > pushover.lastSeenId

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
        visible: (messageRow.message.url || "") !== "" || messageRow.emergency
        text: messageRow.emergency
          ? ((messageRow.message.url || "") !== "" ? "Enter to open · a to acknowledge" : "a to acknowledge")
          : (messageRow.message.urlTitle || messageRow.message.url || "")
        color: messageRow.emergency ? root.urgent : Qt.darker(root.foreground, 2.0)
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }
    }
  }
}
