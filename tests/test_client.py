"""Tests for the Pushover Open Client.

Nothing here touches the network or the real filesystem: XDG_* is redirected to
a temp directory before the module is imported, because the module computes its
paths once at import time.
"""

import importlib.util
import json
import os
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

_SANDBOX = tempfile.mkdtemp(prefix="pushover-tests-")
os.environ["XDG_CONFIG_HOME"] = f"{_SANDBOX}/config"
os.environ["XDG_STATE_HOME"] = f"{_SANDBOX}/state"
os.environ["XDG_CACHE_HOME"] = f"{_SANDBOX}/cache"
# Staged action payloads land here. Without this the suite writes into the
# real /run/user/<uid>/pullover and leaves test messages beside live ones.
os.environ["XDG_RUNTIME_DIR"] = f"{_SANDBOX}/run"
os.makedirs(os.environ["XDG_RUNTIME_DIR"], exist_ok=True)

_CLIENT = Path(__file__).resolve().parent.parent / "bin" / "pullover"
_spec = importlib.util.spec_from_loader(
    "pushover_client",
    importlib.machinery.SourceFileLoader("pushover_client", str(_CLIENT)),
)
client = importlib.util.module_from_spec(_spec)
sys.modules["pushover_client"] = client
_spec.loader.exec_module(client)


class StripHtml(unittest.TestCase):
    def test_drops_tags_and_unescapes(self):
        self.assertEqual(
            client.strip_html("<b>Deal</b> &amp; done <font color=\"red\">now</font>"),
            "Deal & done now",
        )

    def test_leaves_plain_text_alone(self):
        self.assertEqual(client.strip_html("no markup here"), "no markup here")


class Urgency(unittest.TestCase):
    def test_maps_pushover_priority_to_notification_urgency(self):
        self.assertEqual(client.urgency_for(-2), "low")
        self.assertEqual(client.urgency_for(-1), "low")
        self.assertEqual(client.urgency_for(0), "normal")
        self.assertEqual(client.urgency_for(1), "critical")
        self.assertEqual(client.urgency_for(2), "critical")


class DeviceName(unittest.TestCase):
    def test_uses_the_short_hostname(self):
        with mock.patch("socket.gethostname", return_value="mish-omarchy.local"):
            self.assertEqual(client.suggested_device_name(), "mish-omarchy")

    def test_strips_characters_pushover_rejects(self):
        with mock.patch("socket.gethostname", return_value="my box!"):
            self.assertEqual(client.suggested_device_name(), "my-box")

    def test_truncates_to_the_25_char_limit(self):
        with mock.patch("socket.gethostname", return_value="a" * 40):
            self.assertEqual(len(client.suggested_device_name()), 25)

    def test_falls_back_when_the_hostname_is_unusable(self):
        with mock.patch("socket.gethostname", return_value="!!!"):
            self.assertEqual(client.suggested_device_name(), "omarchy")


class StatusFile(unittest.TestCase):
    def setUp(self):
        self.status = client.Status()

    def test_newest_message_is_first(self):
        self.status.record([
            {"id": 1, "title": "old", "message": "a", "date": 100},
            {"id": 2, "title": "new", "message": "b", "date": 200},
        ])
        self.assertEqual([m["title"] for m in self.status.messages], ["new", "old"])

    def test_history_is_capped(self):
        self.status.record([
            {"id": i, "title": str(i), "message": "x", "date": i}
            for i in range(client.MESSAGE_HISTORY + 25)
        ])
        self.assertEqual(len(self.status.messages), client.MESSAGE_HISTORY)

    def test_html_bodies_are_flattened_for_the_widget(self):
        self.status.record([
            {"id": 1, "title": "t", "message": "<b>bold</b>", "date": 1, "html": 1},
        ])
        self.assertEqual(self.status.messages[0]["message"], "bold")

    def test_write_then_clear_round_trips(self):
        self.status.connected = True
        self.status.record([{"id": 7, "title": "t", "message": "m", "date": 5}])
        self.status.write()

        written = json.loads(client.STATUS_PATH.read_text())
        self.assertEqual(written["schemaVersion"], 1)
        self.assertTrue(written["connected"])
        self.assertEqual(written["messages"][0]["id"], 7)

        self.status.clear()
        # An absent file is how the widget knows the daemon stopped, so clear()
        # must actually remove it rather than blank it.
        self.assertFalse(client.STATUS_PATH.exists())

    def test_clear_is_safe_when_nothing_was_written(self):
        self.status.clear()
        self.status.clear()


class BodyMarkup(unittest.TestCase):
    def test_a_plain_body_is_escaped_because_omarchy_renders_StyledText(self):
        body = client.body_for_notification({"message": "5 < 6 & rising"})
        self.assertEqual(body, "5 &lt; 6 &amp; rising")

    def test_an_html_body_is_passed_through_for_the_renderer(self):
        body = client.body_for_notification({"message": "<b>Sold</b>", "html": 1})
        self.assertEqual(body, "<b>Sold</b>")


class DndBypass(unittest.TestCase):
    def test_only_high_and_emergency_bypass(self):
        self.assertFalse(client.bypasses_dnd(-1))
        self.assertFalse(client.bypasses_dnd(0))
        self.assertTrue(client.bypasses_dnd(1))
        self.assertTrue(client.bypasses_dnd(2))


class NativeNotification(unittest.TestCase):
    def _argv(self, message):
        return client.notification_argv(message, None, native=True)

    def test_a_normal_push_keeps_its_app_name(self):
        argv = self._argv({"title": "t", "message": "m", "app": "Ridekick", "priority": 0})
        self.assertEqual(argv[argv.index("--app-name") + 1], "Ridekick")

    def test_a_high_priority_push_drops_the_app_name_to_clear_DND(self):
        # Omarchy grants the bypass to 'omarchy-action' only, which is the
        # sender's default, so the app name has to go.
        argv = self._argv({"title": "Alert", "message": "m", "app": "Ridekick", "priority": 1})
        self.assertNotIn("--app-name", argv)

    def test_the_sender_moves_into_the_headline_when_it_is_dropped(self):
        argv = self._argv({"title": "Alert", "message": "m", "app": "Ridekick", "priority": 1})
        self.assertIn("Ridekick: Alert", argv)

    def test_the_headline_is_not_doubled_when_it_already_names_the_sender(self):
        argv = self._argv({"title": "Ridekick down", "message": "m", "app": "Ridekick", "priority": 1})
        self.assertIn("Ridekick down", argv)
        self.assertNotIn("Ridekick: Ridekick down", argv)

    def test_a_url_becomes_a_click_action_rather_than_body_text(self):
        argv = self._argv({"title": "t", "message": "m", "priority": 0, "url": "https://example.com"})
        self.assertEqual(argv[-3:], ["--exec", "xdg-open", "https://example.com"])
        self.assertNotIn("https://example.com", argv[argv.index("m")])

    def test_an_emergency_push_does_not_expire(self):
        argv = self._argv({"title": "t", "message": "m", "priority": 2})
        self.assertEqual(argv[argv.index("--expire-time") + 1], "0")


class FallbackNotification(unittest.TestCase):
    def _argv(self, message):
        return client.notification_argv(message, None, native=False)

    def test_falls_back_to_notify_send(self):
        argv = self._argv({"title": "t", "message": "m", "app": "A", "priority": 0})
        self.assertEqual(argv[0], "notify-send")
        self.assertEqual(argv[-2:], ["t", "m"])

    def test_the_url_is_appended_to_the_body_when_there_is_no_click_action(self):
        argv = self._argv({
            "title": "t", "message": "m", "priority": 0,
            "url": "https://example.com", "url_title": "Open admin",
        })
        self.assertEqual(argv[-1], "m\nOpen admin")


class NotifyDispatch(unittest.TestCase):
    def test_missing_both_senders_does_not_raise(self):
        with mock.patch.object(client.shutil, "which", return_value=None):
            client.notify({"title": "t", "message": "m"})

    def test_the_native_sender_is_preferred(self):
        with mock.patch.object(client.shutil, "which", side_effect=lambda n: "/usr/bin/" + n), \
             mock.patch.object(client, "icon_path", return_value=None), \
             mock.patch.object(client.subprocess, "run",
                               return_value=mock.Mock(returncode=0)) as run:
            self.assertTrue(client.notify({"title": "t", "message": "m", "priority": 0}))
        self.assertEqual(run.call_args[0][0][0], "omarchy-notification-send")

    def test_a_failing_native_sender_falls_back_rather_than_losing_the_push(self):
        calls = []

        def run(argv, **kwargs):
            calls.append(argv[0])
            return mock.Mock(returncode=1 if argv[0] == "omarchy-notification-send" else 0)

        with mock.patch.object(client.shutil, "which", side_effect=lambda n: "/usr/bin/" + n), \
             mock.patch.object(client, "icon_path", return_value=None), \
             mock.patch.object(client.subprocess, "run", side_effect=run):
            self.assertTrue(client.notify({"title": "t", "message": "m", "priority": 0}))
        self.assertEqual(calls, ["omarchy-notification-send", "notify-send"])

    def test_notify_reports_failure_so_the_caller_can_say_so(self):
        with mock.patch.object(client.shutil, "which", side_effect=lambda n: "/usr/bin/" + n), \
             mock.patch.object(client, "icon_path", return_value=None), \
             mock.patch.object(client.subprocess, "run",
                               return_value=mock.Mock(returncode=1)):
            self.assertFalse(client.notify({"title": "t", "message": "m", "priority": 0}))


class Login(unittest.TestCase):
    def setUp(self):
        client.CREDENTIALS_PATH.unlink(missing_ok=True)

    def test_requires_both_email_and_password(self):
        result = client.perform_login("", "", "", "omarchy", False)
        self.assertFalse(result["ok"])
        self.assertIn("required", result["error"])

    def test_rejects_a_device_name_pushover_would_reject(self):
        result = client.perform_login("a@b.com", "pw", "", "has spaces", False)
        self.assertFalse(result["ok"])
        self.assertIn("Device name", result["error"])

    def test_403_reads_as_a_rejected_login(self):
        # The docs say 401; the API answers 403. Both are the same to a user.
        for status in (401, 403):
            with mock.patch.object(client, "api_post", return_value=mock.Mock(status_code=status, ok=False)):
                result = client.perform_login("a@b.com", "pw", "", "omarchy", False)
            self.assertFalse(result["ok"], status)
            self.assertIn("rejected", result["error"])

    def test_412_asks_for_a_code_rather_than_failing(self):
        with mock.patch.object(client, "api_post", return_value=mock.Mock(status_code=412, ok=False)):
            result = client.perform_login("a@b.com", "pw", "", "omarchy", False)
        self.assertTrue(result["needsTwofa"])

    def test_a_successful_login_saves_credentials_mode_600(self):
        login = mock.Mock(status_code=200, ok=True)
        login.json.return_value = {"secret": "s3cret"}
        device = mock.Mock(status_code=200, ok=True)
        device.json.return_value = {"id": "dev123"}

        with mock.patch.object(client, "api_post", side_effect=[login, device]):
            result = client.perform_login("a@b.com", "pw", "", "omarchy", False)

        self.assertTrue(result["ok"])
        saved = json.loads(client.CREDENTIALS_PATH.read_text())
        self.assertEqual(saved["device_id"], "dev123")
        self.assertEqual(saved["secret"], "s3cret")
        # The secret is the whole account; it must never be group or world readable.
        self.assertEqual(client.CREDENTIALS_PATH.stat().st_mode & 0o077, 0)

    def test_an_existing_login_is_not_replaced_without_force(self):
        client.save_credentials({"secret": "x", "device_id": "y", "device_name": "z"})
        result = client.perform_login("a@b.com", "pw", "", "omarchy", False)
        self.assertFalse(result["ok"])
        self.assertIn("Already logged in", result["error"])

    def test_the_device_error_from_pushover_is_passed_through(self):
        login = mock.Mock(status_code=200, ok=True)
        login.json.return_value = {"secret": "s"}
        device = mock.Mock(status_code=400, ok=False)
        device.json.return_value = {"errors": ["name has already been taken"]}

        with mock.patch.object(client, "api_post", side_effect=[login, device]):
            result = client.perform_login("a@b.com", "pw", "", "omarchy", False)

        self.assertFalse(result["ok"])
        self.assertIn("already been taken", result["error"])


class ServiceState(unittest.TestCase):
    def test_reads_the_word_not_the_exit_code(self):
        # systemctl is-active exits non-zero for an inactive unit, so a naive
        # returncode check would report every stopped service as unknown.
        with mock.patch.object(client, "systemctl", side_effect=[(False, "inactive"), (True, "enabled")]):
            state = client.service_state()
        self.assertFalse(state["active"])
        self.assertTrue(state["enabled"])


if __name__ == "__main__":
    unittest.main(verbosity=2)


class StatusHistorySurvivesRestart(unittest.TestCase):
    def test_load_adopts_what_is_already_on_disk(self):
        first = client.Status()
        first.record([{"id": 9, "idStr": "9", "title": "kept", "message": "m", "date": 1}])
        first.write()

        second = client.Status()
        second.load()
        self.assertEqual([m["title"] for m in second.messages], ["kept"])

    def test_load_ignores_a_file_it_cannot_use(self):
        client.STATUS_PATH.write_text("not json")
        status = client.Status()
        status.load()
        self.assertEqual(status.messages, [])

    def test_load_is_silent_when_there_is_no_file(self):
        client.STATUS_PATH.unlink(missing_ok=True)
        status = client.Status()
        status.load()
        self.assertEqual(status.messages, [])

    def test_load_backfills_idStr_on_a_file_written_before_it_existed(self):
        client.STATUS_PATH.parent.mkdir(parents=True, exist_ok=True)
        client.STATUS_PATH.write_text(json.dumps({
            "schemaVersion": 1,
            "messages": [{"id": 1182737485987742200, "title": "t", "message": "m", "date": 1}],
        }))
        status = client.Status()
        status.load()
        self.assertEqual(status.messages[0]["idStr"], "1182737485987742200")


class Trial(unittest.TestCase):
    def setUp(self):
        client.CREDENTIALS_PATH.unlink(missing_ok=True)
        client.TRIAL_WARNED_PATH.unlink(missing_ok=True)

    def test_unknown_when_not_signed_in(self):
        self.assertFalse(client.trial_state()["known"])

    def test_counts_down_from_the_registration_date(self):
        client.save_credentials({
            "secret": "s", "device_id": "d", "device_name": "n",
            "registered_at": int(time.time()) - 25 * 86400,
        })
        self.assertEqual(client.trial_state()["daysRemaining"], 5)

    def test_never_goes_negative(self):
        client.save_credentials({
            "secret": "s", "device_id": "d", "device_name": "n",
            "registered_at": int(time.time()) - 99 * 86400,
        })
        self.assertEqual(client.trial_state()["daysRemaining"], 0)

    def test_falls_back_to_the_credentials_mtime_for_an_older_install(self):
        # Written before registered_at existed.
        client.save_credentials({"secret": "s", "device_id": "d", "device_name": "n"})
        state = client.trial_state()
        self.assertTrue(state["known"])
        self.assertEqual(state["daysRemaining"], client.TRIAL_DAYS)

    def test_a_licensed_device_is_not_warned(self):
        client.save_credentials({
            "secret": "s", "device_id": "d", "device_name": "n",
            "registered_at": int(time.time()) - 29 * 86400, "licensed": True,
        })
        with mock.patch.object(client, "notify") as notify:
            c = client.Client({"secret": "s", "device_id": "d"})
            c.maybe_warn_about_trial()
        notify.assert_not_called()

    def test_warns_once_per_threshold_and_not_again(self):
        client.save_credentials({
            "secret": "s", "device_id": "d", "device_name": "n",
            "registered_at": int(time.time()) - 25 * 86400,
        })
        with mock.patch.object(client, "notify") as notify:
            c = client.Client({"secret": "s", "device_id": "d"})
            c.maybe_warn_about_trial()
            self.assertEqual(notify.call_count, 1)
            self.assertIn("5 days", notify.call_args[0][0]["title"])
            # The hourly gate, and then the recorded threshold, both hold.
            c._trial_checked_at = 0.0
            c.maybe_warn_about_trial()
            self.assertEqual(notify.call_count, 1)


class OptionSafety(unittest.TestCase):
    def test_a_title_that_is_a_flag_cannot_reach_option_position(self):
        # The real sender exits 1 and displays nothing for a bare "--urgency".
        self.assertEqual(client.option_safe("--urgency"), "⁠--urgency")
        self.assertEqual(client.option_safe("--app-name=Evil"), "⁠--app-name=Evil")

    def test_ordinary_text_is_untouched(self):
        self.assertEqual(client.option_safe("Deal closed"), "Deal closed")

    def test_only_http_urls_become_a_click_action(self):
        self.assertTrue(client.url_is_openable("https://example.com"))
        self.assertTrue(client.url_is_openable("http://example.com"))
        for hostile in ("file:///etc/passwd", "ssh://host", "javascript:alert(1)", ""):
            self.assertFalse(client.url_is_openable(hostile), hostile)

    def test_a_non_http_url_is_dropped_from_the_argv(self):
        argv = client.notification_argv(
            {"title": "t", "message": "m", "priority": 0, "url": "file:///etc/passwd"},
            None, native=True)
        self.assertNotIn("--exec", argv)


class MalformedPayloads(unittest.TestCase):
    """Every one of these used to kill the daemon, which systemd restarted into
    the same batch every five seconds, re-notifying each time."""

    def setUp(self):
        # Client.__init__ adopts the history on disk, so a status file left by
        # an earlier test leaks into this one's assertions.
        client.STATUS_PATH.unlink(missing_ok=True)

    def _sync(self, messages):
        c = client.Client({"secret": "s", "device_id": "d"})
        response = mock.Mock(ok=True)
        response.json.return_value = {"messages": messages}
        with mock.patch.object(client, "api_get", return_value=response), \
             mock.patch.object(client, "api_post", return_value=mock.Mock(ok=True)), \
             mock.patch.object(client, "notify", return_value=True):
            c.sync_messages()
        return c

    def test_a_string_id_does_not_raise(self):
        self._sync([{"id": "abc", "title": "t", "message": "m", "date": 1}])

    def test_a_batch_with_no_usable_id_does_not_raise(self):
        self._sync([{"title": "t", "message": "m", "date": 1}])

    def test_a_string_priority_does_not_raise(self):
        self._sync([{"id": 5, "title": "t", "message": "m", "date": 1, "priority": "high"}])

    def test_a_string_date_does_not_raise(self):
        self._sync([{"id": 5, "title": "t", "message": "m", "date": "2026-01-01"}])

    def test_a_failed_notification_is_recorded_rather_than_dropped(self):
        c = client.Client({"secret": "s", "device_id": "d"})
        response = mock.Mock(ok=True)
        response.json.return_value = {"messages": [{"id": 5, "title": "t", "message": "m", "date": 1}]}
        with mock.patch.object(client, "api_get", return_value=response), \
             mock.patch.object(client, "api_post", return_value=mock.Mock(ok=True)), \
             mock.patch.object(client, "notify", return_value=False):
            c.sync_messages()
        self.assertIn("could not be displayed", c.status.last_error)
        self.assertEqual(len(c.status.messages), 1)


class SecretRedaction(unittest.TestCase):
    def test_the_secret_never_reaches_the_state_file(self):
        client.register_secret("SUPERSECRET")
        try:
            text = client.redact(
                "HTTPSConnectionPool: url /1/messages.json?secret=SUPERSECRET&device_id=d")
            self.assertNotIn("SUPERSECRET", text)
            self.assertIn("[redacted]", text)
        finally:
            client._REDACTIONS.clear()


class TrialWarnings(unittest.TestCase):
    def setUp(self):
        client.CREDENTIALS_PATH.unlink(missing_ok=True)
        client.TRIAL_WARNED_PATH.unlink(missing_ok=True)

    def _fire(self, days_ago):
        client.save_credentials({
            "secret": "s", "device_id": "d", "device_name": "n",
            "registered_at": int(time.time()) - days_ago * 86400,
        })
        titles = []
        c = client.Client({"secret": "s", "device_id": "d"})
        with mock.patch.object(client, "notify",
                               side_effect=lambda m: titles.append(m["title"]) or True):
            for _ in range(3):
                c._trial_checked_at = None
                c.maybe_warn_about_trial()
        return titles

    def test_a_late_start_announces_once_not_once_per_threshold(self):
        self.assertEqual(len(self._fire(29)), 1)

    def test_an_expired_trial_never_says_zero_days(self):
        titles = self._fire(45)
        self.assertEqual(len(titles), 1)
        self.assertIn("has ended", titles[0])
        self.assertNotIn("0 days", titles[0])

    def test_the_first_hour_of_uptime_is_not_a_blind_spot(self):
        client.save_credentials({
            "secret": "s", "device_id": "d", "device_name": "n",
            "registered_at": int(time.time()) - 25 * 86400,
        })
        c = client.Client({"secret": "s", "device_id": "d"})
        # A machine booted 42 seconds ago.
        with mock.patch.object(client.time, "monotonic", return_value=42.0), \
             mock.patch.object(client, "notify", return_value=True) as notify:
            c.maybe_warn_about_trial()
        notify.assert_called_once()


class CredentialRewrites(unittest.TestCase):
    def test_a_rewrite_does_not_restart_the_trial_clock(self):
        client.CREDENTIALS_PATH.unlink(missing_ok=True)
        # A legacy file with no registered_at, dated 20 days ago.
        client.save_credentials({"secret": "s", "device_id": "d", "device_name": "n"})
        old = int(time.time()) - 20 * 86400
        os.utime(client.CREDENTIALS_PATH, (old, old))

        before = client.trial_state()["daysRemaining"]
        with client.CREDENTIALS_PATH.open() as handle:
            creds = json.load(handle)
        creds.pop("registered_at", None)
        client.save_credentials(creds)          # what `licensed --undo` does
        after = client.trial_state()["daysRemaining"]

        self.assertEqual(before, 10)
        self.assertEqual(after, before)


class HistorySurvivesARestart(unittest.TestCase):
    def test_stopping_records_the_state_without_discarding_the_messages(self):
        client.STATUS_PATH.unlink(missing_ok=True)
        first = client.Status()
        first.connected = True
        first.record([{"id": 4, "idStr": "4", "title": "kept", "message": "m", "date": 1}])
        first.write()
        first.stopped()

        written = json.loads(client.STATUS_PATH.read_text())
        self.assertFalse(written["running"])
        self.assertFalse(written["connected"])
        self.assertEqual(len(written["messages"]), 1)

        # Which is the whole point: the next process finds them.
        second = client.Status()
        second.load()
        self.assertEqual([m["title"] for m in second.messages], ["kept"])


class IconCache(unittest.TestCase):
    def test_the_cache_is_bounded_because_the_sender_names_the_icons(self):
        cache = client.cache_dir()
        cache.mkdir(parents=True, exist_ok=True)
        for existing in cache.glob("*.png"):
            existing.unlink()
        for i in range(client.MAX_CACHED_ICONS + 25):
            icon = cache / f"icon{i:04d}.png"
            icon.write_bytes(b"x")
            os.utime(icon, (i, i))          # oldest first

        client.prune_icon_cache()
        remaining = sorted(f.name for f in cache.glob("*.png"))
        self.assertEqual(len(remaining), client.MAX_CACHED_ICONS)
        # The oldest go, the newest stay.
        self.assertNotIn("icon0000.png", remaining)
        self.assertIn(f"icon{client.MAX_CACHED_ICONS + 24:04d}.png", remaining)


class Handlers(unittest.TestCase):
    """Per-sender actions, and the argument that they cannot be hijacked."""

    HANDLER = {
        "handlers": [{
            "name": "ridekick",
            "match": {"app": "Ridekick Admin"},
            "actions": [{"key": "i", "label": "Investigate", "run": ["/bin/true"]}],
        }],
    }

    def setUp(self):
        client.HANDLERS_PATH.parent.mkdir(parents=True, exist_ok=True)
        self._write(self.HANDLER)
        self.addCleanup(client.HANDLERS_PATH.unlink, True)

    def _write(self, data):
        client.HANDLERS_PATH.write_text(
            data if isinstance(data, str) else json.dumps(data))

    def test_a_handler_matches_its_sender_by_exact_app_name(self):
        for app in ("Ridekick Admin", "ridekick admin", "  Ridekick Admin  "):
            self.assertIsNotNone(client.handler_for({"app": app}), app)

    def test_a_sender_that_merely_resembles_the_handlers_gets_nothing(self):
        # The whole safety argument. Substring matching would hand a local
        # command to anything that can put the name somewhere in its own.
        for app in ("Ridekick Admin (staging)", "Not Ridekick Admin",
                    "Ridekick", "Pushover", "", None):
            self.assertIsNone(client.handler_for({"app": app}), app)

    def test_an_unmatched_message_keeps_the_default_click_action(self):
        argv = client.notification_argv(
            {"title": "t", "message": "m", "app": "Pushover", "priority": 0,
             "url": "https://example.com"}, None, native=True)
        self.assertEqual(argv[-3:], ["--exec", "xdg-open", "https://example.com"])

    def test_a_handler_cannot_rebind_a_key_the_panel_already_spends(self):
        self._write({"handlers": [{"match": {"app": "X"}, "actions": [
            {"key": "d", "label": "Dismiss impostor", "run": ["/bin/true"]},
            {"key": "a", "label": "Ack impostor", "run": ["/bin/true"]},
            {"key": "z", "label": "Fine", "run": ["/bin/true"]},
        ]}]})
        keys = [a["key"] for a in client.handler_actions(client.handler_for({"app": "X"}))]
        self.assertEqual(keys, ["z"])

    def test_a_malformed_action_is_dropped_without_its_siblings(self):
        self._write({"handlers": [{"match": {"app": "X"}, "actions": [
            {"key": "q", "label": "No command"},
            {"key": "qq", "label": "Two characters", "run": ["/bin/true"]},
            {"key": "w", "label": "Empty command", "run": []},
            {"key": "e", "label": "Good", "run": ["/bin/true"]},
            {"key": "e", "label": "Duplicate", "run": ["/bin/true"]},
        ]}]})
        keys = [a["key"] for a in client.handler_actions(client.handler_for({"app": "X"}))]
        self.assertEqual(keys, ["e"])

    def test_a_broken_handlers_file_disables_handlers_not_the_client(self):
        for bad in ("{not json", "", "[]", '{"handlers": "nope"}'):
            self._write(bad)
            self.assertEqual(client.load_handlers(), [], bad)
            # ...and a push still renders.
            argv = client.notification_argv(
                {"title": "t", "message": "m", "app": "Ridekick Admin", "priority": 0},
                None, native=True)
            self.assertIn("t", argv)

    def test_nothing_from_the_message_reaches_the_command_line(self):
        # A push title is whatever the sender put in it. The handler gets one
        # argument -- a path we chose -- and reads the rest out of the file.
        hostile = '$(touch /tmp/pwned); `id`; "; \n--urgency'
        message = {"app": "Ridekick Admin", "title": hostile, "message": hostile,
                   "id": 1, "id_str": "1", "priority": 0}
        with mock.patch.object(client.subprocess, "Popen") as popen:
            self.assertEqual(client.run_action(message, "i"), 0)
        argv = popen.call_args[0][0]
        self.assertEqual(len(argv), 2)
        self.assertEqual(argv[0], "/bin/true")
        self.assertNotIn(hostile, argv)
        # ...and it is all still there, in the file, for the handler to read.
        self.assertEqual(json.loads(Path(argv[1]).read_text())["title"], hostile)

    def test_the_payload_is_not_world_readable(self):
        message = {"app": "Ridekick Admin", "title": "t", "id": 2, "id_str": "2"}
        path = client.write_action_payload(message)
        self.assertEqual(oct(path.stat().st_mode)[-3:], "600")

    def test_an_unconfigured_key_runs_nothing(self):
        with mock.patch.object(client.subprocess, "Popen") as popen:
            self.assertEqual(
                client.run_action({"app": "Ridekick Admin", "id_str": "3"}, "z"), 1)
            self.assertEqual(
                client.run_action({"app": "Pushover", "id_str": "3"}, "i"), 1)
        popen.assert_not_called()

    def test_a_toast_action_replaces_opening_the_url(self):
        self._write({"handlers": [{
            "match": {"app": "Ridekick Admin"}, "toast": "i",
            "actions": [{"key": "i", "label": "Investigate", "run": ["/bin/true"]}],
        }]})
        argv = client.notification_argv(
            {"title": "t", "message": "m", "app": "Ridekick Admin", "priority": 0,
             "id": 4, "id_str": "4", "url": "https://example.com"}, None, native=True)
        self.assertIn("--exec", argv)
        self.assertNotIn("xdg-open", argv)
        self.assertEqual(argv[argv.index("--exec") + 2:argv.index("--exec") + 4],
                         ["action", "i"])

    def test_a_toast_naming_an_unknown_action_falls_back_to_the_url(self):
        self._write({"handlers": [{
            "match": {"app": "Ridekick Admin"}, "toast": "nope",
            "actions": [{"key": "i", "label": "Investigate", "run": ["/bin/true"]}],
        }]})
        argv = client.notification_argv(
            {"title": "t", "message": "m", "app": "Ridekick Admin", "priority": 0,
             "id": 5, "id_str": "5", "url": "https://example.com"}, None, native=True)
        self.assertEqual(argv[-3:], ["--exec", "xdg-open", "https://example.com"])
