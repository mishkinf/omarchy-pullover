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
import unittest
from pathlib import Path
from unittest import mock

_SANDBOX = tempfile.mkdtemp(prefix="pushover-tests-")
os.environ["XDG_CONFIG_HOME"] = f"{_SANDBOX}/config"
os.environ["XDG_STATE_HOME"] = f"{_SANDBOX}/state"
os.environ["XDG_CACHE_HOME"] = f"{_SANDBOX}/cache"

_CLIENT = Path(__file__).resolve().parent.parent / "bin" / "pushover-open-client"
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


class Notify(unittest.TestCase):
    def _argv(self, message):
        with mock.patch.object(client.shutil, "which", return_value="/usr/bin/notify-send"), \
             mock.patch.object(client, "icon_path", return_value=None), \
             mock.patch.object(client.subprocess, "run") as run:
            client.notify(message)
        return run.call_args[0][0]

    def test_carries_title_body_app_and_urgency(self):
        argv = self._argv({"title": "Ridekick", "message": "hi", "app": "Ridekick Admin", "priority": 1})
        self.assertIn("--app-name", argv)
        self.assertEqual(argv[argv.index("--app-name") + 1], "Ridekick Admin")
        self.assertEqual(argv[argv.index("--urgency") + 1], "critical")
        self.assertEqual(argv[-2:], ["Ridekick", "hi"])

    def test_emergency_pushes_do_not_expire(self):
        argv = self._argv({"title": "t", "message": "m", "priority": 2})
        self.assertEqual(argv[argv.index("--expire-time") + 1], "0")

    def test_ordinary_pushes_keep_the_default_timeout(self):
        argv = self._argv({"title": "t", "message": "m", "priority": 0})
        self.assertNotIn("--expire-time", argv)

    def test_the_url_is_appended_to_the_body(self):
        argv = self._argv({
            "title": "t", "message": "m", "priority": 0,
            "url": "https://example.com", "url_title": "Open admin",
        })
        self.assertEqual(argv[-1], "m\nOpen admin")

    def test_missing_notify_send_does_not_raise(self):
        with mock.patch.object(client.shutil, "which", return_value=None):
            client.notify({"title": "t", "message": "m"})


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
