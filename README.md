# Pushover for Omarchy

Pushover ships apps for iOS, Android, macOS and the browser, and nothing for
Linux. This is the missing client: every push that reaches your phone reaches
your desktop, as a native Omarchy notification, with a bar widget for the ones
you missed.

![The Pushover panel in the Omarchy bar](preview.png)

## What it does

- **Native notifications.** Pushes arrive through the Omarchy shell's own
  notification daemon, with the sending app's icon and name. Priority maps to
  urgency, and an emergency push does not time out on its own.
- **A bell in the bar** with an unread count, and a panel listing recent pushes.
- **Acknowledge an emergency push** from the desktop, without reaching for the
  phone.
- **Sign in from the panel.** No terminal step, no config file to hand-edit.

## How it works

Pushover's [Open Client API](https://pushover.net/api/client) lets a device
register itself and hold a websocket to `client.pushover.net`. The socket
carries no content — single bytes meaning "something changed" — so the client
fetches messages over HTTPS, shows them, and tells the server they landed.

Two pieces, and the first is useful without the second:

| | |
| --- | --- |
| `pushover-open-client` | A Python daemon under systemd. Holds the socket, raises the notifications, writes the state file. |
| The bar widget | QML. Reads that state file. Owns sign-in and "unread". |

## Requirements

- Omarchy 4 or newer (the shell plugin system)
- `python-websockets`, `python-requests`, `libnotify` — `setup` installs these
- **A Pushover for Desktop licence.** Free for 30 days from the moment this
  device registers, then a one-time **$4.99** on your account. A phone or macOS
  app licence does not cover it. <https://pushover.net/clients/desktop>

Nothing warns you when the trial ends — the device simply stops receiving.

## Install

```bash
omarchy plugin add https://github.com/mishkinf/omarchy-pushover.git
cd ~/.config/omarchy/plugins/io.github.mishkinf.pushover && ./setup
omarchy plugin enable io.github.mishkinf.pushover --section right
```

Then **click the bell and sign in there.** The panel asks for your Pushover
email and password, reveals a two-factor field only if the server asks for one,
registers this machine (named after its hostname by default), and starts the
client on success.

The password is never stored and never passed as an argument — it goes to the
client over stdin, because anything in argv is readable by every process on the
machine. What is kept is the device token, in
`~/.config/pushover/credentials.json`, mode 600.

### Uninstall

```bash
./uninstall              # stop and remove the client, keep the login
./uninstall --forget     # also sign this machine out of Pushover
omarchy plugin remove io.github.mishkinf.pushover
```

## Using it

| | |
| --- | --- |
| Click the bell | open the panel, which marks everything read |
| Right-click | re-read the state |
| `j` / `k` | move through messages |
| `Enter` / `o` | open the message's URL |
| `a` | acknowledge an emergency-priority push |
| `r` | refresh |

Priority maps to notification urgency: <= -1 low, 0 normal, >= 1 critical.

### Settings

`omarchy bar set io.github.mishkinf.pushover <key> <value>`

| key | default | |
| --- | --- | --- |
| `hideWhenIdle` | `false` | hide the bell when the client is not running |
| `maxVisible` | `12` | messages listed in the panel (50 are kept) |

### From a terminal

```bash
pushover-open-client probe      # signed in? client running?
pushover-open-client status     # the state file the widget reads
pushover-open-client selftest   # prove the notification path works
pushover-open-client ack <receipt>
pushover-open-client logout
journalctl --user -u pushover-open-client -f
```

## When it stops

Two failures stop the client for good, because both need a person. systemd is
told not to restart on them (`RestartPreventExitStatus=78 79`):

- **78** — Pushover rejected this device. Sign in again.
- **79** — the same device id logged in somewhere else. Two copies of this
  client cannot share one device; register the second under another name.

Everything else — a dropped socket, a flaky network, an API 500 — reconnects on
its own with a backoff from 5 seconds to 5 minutes.

## Tests

```bash
./test
```

No network, no Pushover account, no real filesystem. Python covers the client;
Node covers the widget's model, and is skipped if Node is not installed.

## Notes for anyone changing this

Each of these is a bug that actually happened here.

- **A Pushover message id is 19 digits.** That is past JavaScript's safe-integer
  range, so `JSON.parse` rounds it. Observed: id `...742185` became `...742200`,
  and the read marker could then never match any message again. The widget
  compares id **strings** and tracks unread by **position**, never by numeric
  comparison.
- **The delete is sent after the notifications are out.** A crash mid-sync
  re-shows a push rather than losing it. A duplicate notification is a far
  cheaper failure than a missed one.
- **The socket going quiet is indistinguishable from nothing happening**, which
  is why there is a 120-second watchdog rather than trust in the connection.
- **The daemon adopts the history on disk at startup.** Without that, every
  restart wrote an empty message list and the panel forgot everything.
- **Do not reload the read marker while marking read.** The reload returns
  pre-write content and silently un-reads what the user just looked at.
- **Glyphs are surrogate pairs, not the ES6 brace form** — the shell's QML does
  not parse the latter and renders an unparsed escape as a broken box.
- **A nerd-font icon's ink is wider than its one-cell advance.** Sizing a glyph
  box to the text's implicit width cuts the icon in half.
- **A QML hot reload does not re-instantiate a `Loader`'s existing item.** After
  changing anything a `Loader` builds, `omarchy restart shell` before believing
  a screenshot.
- **Pushover answers a bad login with 403**, not the documented 401.
- The widget owns "unread", not the daemon: it is a property of this screen
  having been looked at, which only the widget can know.

## Licence

MIT. See [LICENSE](LICENSE).

Not affiliated with Superblock, LLC, who make Pushover. "Pushover" is their
trademark; this is an independent client built on their published Open Client
API.
