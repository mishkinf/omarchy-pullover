# Pushover for Omarchy

Pushover ships apps for iOS, Android, macOS and the browser, and nothing for
Linux. This plugin is the missing client: every push that reaches your phone
reaches this machine, as a native notification through the Omarchy shell, with
a bar widget for the ones you missed.

![the panel](docs/panel.png)

## How it works

Pushover's [Open Client API](https://pushover.net/api/client) lets a device
register itself and hold a websocket to `client.pushover.net`. The socket
carries no content — single bytes that mean "something changed" — so the client
fetches the messages over HTTPS, shows them, and tells the server they landed.

Two pieces:

- **`pushover-open-client`** — a Python daemon under systemd. Holds the socket,
  raises the notifications, writes `~/.local/state/pushover/status.json`.
- **The bar widget** — reads that file. Unread count on the bell, recent pushes
  in the panel, `a` to acknowledge an emergency push without reaching for the
  phone.

The daemon is useful on its own; the widget is not useful without it.

## Install

```bash
omarchy plugin add https://github.com/mishkinf/omarchy-pushover.git --enable
cd ~/.config/omarchy/plugins/io.github.mishkinf.pushover && ./setup
```

Then **click the bell and sign in there**. The panel asks for your Pushover
email and password, reveals a two-factor field only if the server asks for one,
registers this machine as a device, and starts the client on success. There is
no terminal step.

The password is never stored and never passed as an argument — it goes to the
CLI over stdin, because anything in argv is readable by every process on the
machine. What is kept is the device token, in
`~/.config/pushover/credentials.json`, mode 600.

The same thing from a terminal, if you prefer:

```bash
pushover-open-client login
pushover-open-client probe     # JSON: signed in? client running?
pushover-open-client logout    # stop the client and forget the token
```

**Pushover for Desktop is free for 30 days, then a one-time $4.99 licence** on
your account — a phone or Mac licence does not cover it. An Open Client device
that is not licensed after 30 days stops receiving.
<https://pushover.net/clients/desktop>

## Using it

| | |
| --- | --- |
| Click the bell | open the panel, which marks everything read |
| Right-click | re-read the state file |
| `j` / `k` | move through messages |
| `Enter` / `o` | open the message's URL |
| `a` | acknowledge an emergency-priority push |
| `r` | refresh |

```bash
pushover-open-client selftest   # prove the notification path works
pushover-open-client status     # what the widget is reading
omarchy-shell pushover unread   # the badge count
journalctl --user -u pushover-open-client -f
```

Priority maps to urgency: ≤ -1 low, 0 normal, ≥ 1 critical. Emergency pushes
(priority 2) never time out on their own.

## Settings

`omarchy bar set io.github.mishkinf.pushover <key> <value>`

| key | default | |
| --- | --- | --- |
| `hideWhenIdle` | `false` | hide the bell when the daemon is not running |
| `maxVisible` | `12` | messages listed in the panel (50 are kept) |

## Two failures that stop the daemon for good

Both need a person, so systemd is told not to restart on them
(`RestartPreventExitStatus=78 79`):

- **78** — Pushover rejected the device. Run `pushover-open-client login --force`.
- **79** — the same device id logged in somewhere else. Two copies of this
  client cannot share one device; register the second under another name.

Anything else — a dropped socket, a flaky network, an API 500 — reconnects on
its own with a backoff from 5s to 5 minutes.

## Notes for anyone changing this

- **The delete is sent after the notifications are out.** A crash mid-sync
  re-shows a push rather than losing it. A duplicate notification is a far
  cheaper failure than a missed one.
- **The socket going quiet is indistinguishable from nothing happening**, which
  is why there is a 120s watchdog rather than trust in the connection.
- **Glyphs are surrogate pairs, not `\u{...}`** — the shell's QML does not parse
  the ES6 form and renders an unparsed escape as a broken box.
- **A nerd-font icon's ink is wider than its one-cell advance.** Sizing a glyph
  box to the text's implicit width cuts the bell in half. Give the box room and
  centre the glyph in it.
- **A QML hot reload does not re-instantiate a `Loader`'s existing item.** After
  changing anything a `Loader` builds, `omarchy restart shell` before believing
  a screenshot.
- The widget owns "unread", not the daemon: it is a property of this screen
  having been looked at, which only the widget can know.

## Licence

MIT.
