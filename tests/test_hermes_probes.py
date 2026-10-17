"""Offline tests for the Hermes probes. Standard library only, like the probes.

Run: python3 -m unittest tests/test_hermes_probes.py (test-plugins.sh runs it).
"""

import importlib.util
import json
import os
import sqlite3
import sys
import tempfile
import time
import unittest
from pathlib import Path

LIBEXEC = Path(__file__).resolve().parent.parent / "rootfs/usr/local/nagios/libexec"


def load(name):
    spec = importlib.util.spec_from_file_location(name.replace(".py", ""), LIBEXEC / name)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


platforms = load("check_hermes_platforms.py")
context = load("check_hermes_context.py")

ME = os.getpid()
MY_START = int(Path(f"/proc/{ME}/stat").read_text().rsplit(") ", 1)[1].split()[19])


def platform(state="connected", pid=ME, start=MY_START, **extra):
    return {
        "state": state,
        "error_code": None,
        "error_message": None,
        "writer_pid": pid,
        "writer_start_time": start,
        **extra,
    }


class Platforms(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.data = Path(self.dir.name)
        (self.data / "logs").mkdir()

    def tearDown(self):
        self.dir.cleanup()

    def write(self, gateway_state="running", **plats):
        state = {
            "gateway_state": gateway_state,
            "exit_reason": None,
            "updated_at": "2026-10-17T04:00:00+00:00",
            "platforms": plats,
        }
        (self.data / "gateway_state.json").write_text(json.dumps(state))

    def log(self, *lines):
        (self.data / "logs" / "gateway.log").write_text("\n".join(lines) + "\n")

    def run_check(self, names=("matrix", "webhook")):
        return platforms.check(self.data, list(names), now=time.time())

    def test_live_writers_are_ok(self):
        self.write(matrix=platform(), webhook=platform())
        self.log("2026-10-17 01:00:00 Matrix: initial sync complete")
        code, out = self.run_check()
        self.assertEqual(code, 0, out)
        self.assertIn("2/2 platforms connected and verified: matrix webhook", out)

    def test_missing_state_file_is_unknown(self):
        self.assertEqual(self.run_check()[0], 3)

    def test_gateway_not_running_is_critical(self):
        self.write(gateway_state="stopped")
        self.assertEqual(self.run_check()[0], 2)

    def test_missing_platform_is_critical(self):
        self.write(matrix=platform())
        code, out = self.run_check()
        self.assertEqual(code, 2)
        self.assertIn("webhook missing from gateway_state", out)

    def test_disconnected_platform_names_the_error(self):
        self.write(matrix=platform(state="fatal", error_code="auth"), webhook=platform())
        code, out = self.run_check()
        self.assertEqual(code, 2)
        self.assertIn("matrix is 'fatal' [auth]", out)

    def test_vanished_writer_is_critical(self):
        self.write(matrix=platform(pid=2**22 + 7), webhook=platform())
        code, out = self.run_check()
        self.assertEqual(code, 2)
        self.assertIn("is gone", out)

    def test_unreadable_writer_stat_names_the_error(self):
        proc = Path(self.dir.name) / "proc"
        (proc / "42" / "stat").mkdir(parents=True)  # reading a directory fails, but not as "gone"
        self.write(matrix=platform(pid=42), webhook=platform())
        code, out = platforms.check(self.data, ["webhook", "matrix"], proc=proc)
        self.assertEqual(code, 2)
        self.assertIn("writer pid 42 cannot be checked", out)

    def test_recycled_writer_is_critical(self):
        self.write(matrix=platform(start=MY_START + 1), webhook=platform())
        code, out = self.run_check()
        self.assertEqual(code, 2)
        self.assertIn("was recycled", out)

    def test_stop_after_last_sync_is_critical(self):
        self.write(matrix=platform(), webhook=platform())
        self.log(
            "2026-10-17 01:00:00 Matrix: initial sync complete",
            "2026-10-17 02:00:00 Matrix: permanent auth error, stopping sync",
        )
        code, out = self.run_check()
        self.assertEqual(code, 2)
        self.assertIn("matrix sync loop stopped at 2026-10-17 02:00:00", out)
        self.assertIn("platforms_ok=1;", out)

    def test_resync_after_stop_is_ok(self):
        self.write(matrix=platform(), webhook=platform())
        self.log("2026-10-17 01:00:00 Matrix: disconnected", "2026-10-17 02:00:00 Matrix: initial sync complete")
        code, out = self.run_check()
        self.assertEqual(code, 0, out)
        self.assertIn("matrix synced 2026-10-17 02:00:00", out)

    def test_stop_in_a_rotated_log_is_still_seen(self):
        self.write(matrix=platform(), webhook=platform())
        self.log("2026-10-17 03:00:00 unrelated")
        (self.data / "logs" / "errors.log.1").write_text("2026-10-17 02:00:00 Matrix: disconnected\n")
        code, out = self.run_check()
        self.assertEqual(code, 2)
        self.assertIn("stopped at 2026-10-17 02:00:00", out)

    def test_no_logs_is_not_health(self):
        self.write(matrix=platform(), webhook=platform())
        code, out = self.run_check()
        self.assertEqual(code, 2)
        self.assertIn("cannot be verified: no errors.log or gateway.log", out)

    def test_unreadable_log_is_not_health(self):
        self.write(matrix=platform(), webhook=platform())
        (self.data / "logs" / "gateway.log").mkdir()  # reading a directory fails
        code, out = self.run_check()
        self.assertEqual(code, 2)
        self.assertIn("cannot read gateway.log", out)

    def test_webhook_alone_needs_no_logs(self):
        self.write(webhook=platform())
        self.assertEqual(self.run_check(names=("webhook",))[0], 0)

    def test_sync_stop_does_not_discount_a_matrix_already_failed(self):
        # The bash version subtracted from the good count a second time here.
        self.write(matrix=platform(state="fatal"), webhook=platform())
        self.log("2026-10-17 02:00:00 Matrix: disconnected")
        code, out = self.run_check()
        self.assertEqual(code, 2)
        self.assertIn("platforms_ok=1;", out)


class Context(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.data = Path(self.dir.name)
        self.now = time.time()
        with sqlite3.connect(self.data / "state.db") as db:
            db.execute("CREATE TABLE sessions (id TEXT, ended_at REAL)")
            db.execute(
                "CREATE TABLE messages (session_id TEXT, role TEXT, content TEXT, active INT, "
                "compacted INT, timestamp REAL)"
            )

    def tearDown(self):
        self.dir.cleanup()

    def session(self, sid, chars, ended=None, age_h=1):
        with sqlite3.connect(self.data / "state.db") as db:
            db.execute("INSERT INTO sessions VALUES (?, ?)", (sid, ended))
        self.message(sid, "user", chars, age_h=age_h)

    def message(self, sid, role, chars, age_h=1, compacted=False):
        with sqlite3.connect(self.data / "state.db") as db:
            db.execute(
                "INSERT INTO messages VALUES (?, ?, ?, ?, ?, ?)",
                (sid, role, "x" * chars, int(not compacted), int(compacted), self.now - age_h * 3600),
            )

    def run_check(self, **kw):
        limits = context.Limits(**{"overhead": 0, "fallback": 1000, **kw})
        return context.check(self.data, limits, now=self.now)

    def test_no_open_session_is_ok(self):
        self.session("old", 100, ended=self.now)
        code, out = self.run_check()
        self.assertEqual(code, 0)
        self.assertIn("no open Hermes session", out)

    def test_only_active_rows_count(self):
        self.session("s", 400)  # 100 tokens = 10% of 1000
        for _ in range(3):
            self.message("s", "user", 10**6, compacted=True)
        code, out = self.run_check()
        self.assertEqual(code, 0, out)
        self.assertIn("ctx_pct=10%", out)
        self.assertIn("1 active of 4 rows", out)
        self.assertIn("inactive=3", out)

    def test_thresholds(self):
        self.session("s", 3000)  # 750 tokens = 75%
        self.assertEqual(self.run_check()[0], 1)
        self.assertEqual(self.run_check(warn_pct=80, crit_pct=70)[0], 2)

    def test_stale_open_session_is_ignored(self):
        self.session("stale", 3600, age_h=24 * 30)
        self.assertIn("no open Hermes session", self.run_check()[1])

    def test_config_context_length_wins(self):
        (self.data / "config.yaml").write_text("model:\n  context_length: 2000\n")
        self.session("s", 400)
        self.assertIn("source=config", self.run_check()[1])

    def test_tool_share(self):
        self.session("s", 100)
        self.message("s", "tool", 300)
        self.assertIn("tool_pct=75%", self.run_check()[1])

    def test_failed_query_is_unknown_not_ok(self):
        # The bash version suppressed sqlite3 errors and reported OK.
        (self.data / "state.db").write_bytes(b"not a database")
        code, out = self.run_check()
        self.assertEqual(code, 3)
        self.assertIn("cannot query", out)

    def test_unreadable_config_is_named(self):
        (self.data / "config.yaml").mkdir()  # reading a directory raises IsADirectoryError
        self.session("s", 400)
        self.assertIn("config unreadable", self.run_check()[1])

    def test_missing_database_is_unknown(self):
        (self.data / "state.db").unlink()
        self.assertEqual(self.run_check()[0], 3)


if __name__ == "__main__":
    sys.exit(unittest.main())
