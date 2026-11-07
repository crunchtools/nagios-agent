"""check_deployer.sh: every verdict path, against a real state directory.

The precedence is the part worth testing. A hold with no guard outranks a stale
hold, which outranks a failed rollback, which outranks a plain hold — because
"nothing is honouring this hold" is the one that means the rolled-back image is
going live again tonight.
"""

from __future__ import annotations

import json
import os
import subprocess
import time
from pathlib import Path

import pytest

CHECK = Path(__file__).resolve().parents[1] / "rootfs/usr/local/nagios/libexec/check_deployer.sh"

OK = 0
WARNING = 1
CRITICAL = 2
UNKNOWN = 3
STALE_HOLD_SECONDS = 24 * 60 * 60


@pytest.fixture
def guard(tmp_path: Path) -> Path:
    """A stub systemctl that reports an ExecCondition, i.e. the guard installed."""
    path = tmp_path / "systemctl-with-guard"
    path.write_text('#!/bin/sh\necho "/usr/bin/test -x /var/lib/deployer/hold"\n', encoding="utf-8")
    path.chmod(0o755)
    return path


@pytest.fixture
def no_guard(tmp_path: Path) -> Path:
    """A stub systemctl that reports nothing, i.e. the guard missing."""
    path = tmp_path / "systemctl-no-guard"
    path.write_text("#!/bin/sh\necho\n", encoding="utf-8")
    path.chmod(0o755)
    return path


def state(tmp_path: Path) -> Path:
    directory = tmp_path / "state" / "hold"
    directory.mkdir(parents=True, exist_ok=True)
    return directory.parent


def place_hold(
    state_dir: Path, unit: str = "acquacotta.crunchtools.com.service", ticket: int = 1234, age_seconds: int = 0
) -> Path:
    path = state_dir / "hold" / unit
    path.write_text(json.dumps({"unit": unit, "ticket": ticket, "revision": "f" * 40}), encoding="utf-8")
    if age_seconds:
        placed = time.time() - age_seconds
        os.utime(path, (placed, placed))
    return path


def write_status(state_dir: Path, outcome: str, whole: bool = True) -> None:
    lines = [f"DEPLOYER generated={int(time.time())} outcome={outcome} detail=x"]
    if whole:
        lines.append("DEPLOYER end=1")
    (state_dir / "deployer.status").write_text("\n".join(lines) + "\n", encoding="utf-8")


def run(state_dir: Path | str, systemctl: Path | None = None) -> subprocess.CompletedProcess[str]:
    env = dict(os.environ)
    if systemctl is not None:
        env["SYSTEMCTL"] = str(systemctl)
    return subprocess.run(["bash", str(CHECK), str(state_dir)], capture_output=True, text=True, env=env, check=False)


def test_a_missing_state_directory_is_unknown(guard: Path) -> None:
    # Not CRITICAL: the deployer may simply not be installed on this host, and
    # a check cannot tell that from a broken one.
    result = run("/nonexistent-deployer-state", guard)
    assert result.returncode == UNKNOWN
    assert "UNKNOWN" in result.stdout


def test_no_holds_and_a_guard_is_ok(tmp_path: Path, guard: Path) -> None:
    result = run(state(tmp_path), guard)
    assert result.returncode == OK
    assert "no deployer holds" in result.stdout
    assert "held=0" in result.stdout


def test_a_hold_is_a_warning(tmp_path: Path, guard: Path) -> None:
    directory = state(tmp_path)
    place_hold(directory)
    result = run(directory, guard)
    assert result.returncode == WARNING
    assert "1 deployer hold(s)" in result.stdout
    # The unit, its age and the ticket, so the alert names what to go and read.
    assert "acquacotta.crunchtools.com.service:0h:1234" in result.stdout


def test_a_hold_with_no_guard_is_critical(tmp_path: Path, no_guard: Path) -> None:
    # The important one. A hold nothing honours reads as protection that is not
    # there, and the rolled-back image goes live at the next auto-update.
    directory = state(tmp_path)
    place_hold(directory)
    result = run(directory, no_guard)
    assert result.returncode == CRITICAL
    assert "nothing honours them" in result.stdout


def test_no_guard_without_a_hold_is_only_a_warning(tmp_path: Path, no_guard: Path) -> None:
    # Nothing is at risk yet; it is still wrong and still worth saying.
    result = run(state(tmp_path), no_guard)
    assert result.returncode == WARNING
    assert "would not stick" in result.stdout


def test_a_hold_standing_a_day_is_critical(tmp_path: Path, guard: Path) -> None:
    directory = state(tmp_path)
    place_hold(directory, age_seconds=STALE_HOLD_SECONDS + 3600)
    result = run(directory, guard)
    assert result.returncode == CRITICAL
    assert "fleet updates are frozen" in result.stdout


def test_a_refused_ticket_is_not_reported_here(tmp_path: Path, guard: Path) -> None:
    # A refusal is a DECIDED state: the deployer exits 0 for one and the
    # stalled ticket is the channel. Warning here would contradict that, and
    # would outlast the problem -- this file is rewritten only when a ticket
    # runs, so a refusal on Tuesday would still be amber on Friday.
    directory = state(tmp_path)
    write_status(directory, "refused")
    result = run(directory, guard)
    assert result.returncode == OK


def test_a_rolled_back_outcome_is_left_to_the_hold(tmp_path: Path, guard: Path) -> None:
    # The hold is live state and is already reported. The outcome is history.
    directory = state(tmp_path)
    write_status(directory, "rolled-back")
    result = run(directory, guard)
    assert result.returncode == OK


def test_a_could_not_run_outcome_is_a_warning(tmp_path: Path, guard: Path) -> None:
    # Nothing else reports this one: the deployer could not work at all.
    directory = state(tmp_path)
    write_status(directory, "could-not-run")
    result = run(directory, guard)
    assert result.returncode == WARNING
    assert "could-not-run" in result.stdout


def test_a_failed_rollback_is_critical(tmp_path: Path, guard: Path) -> None:
    directory = state(tmp_path)
    write_status(directory, "rollback-failed")
    result = run(directory, guard)
    assert result.returncode == CRITICAL
    assert "rollback did not verify" in result.stdout


def test_a_truncated_status_file_is_a_warning(tmp_path: Path, guard: Path) -> None:
    # Without end=1 the contents are not evidence of anything, so the check
    # says so rather than reading a half-written outcome as "ok".
    directory = state(tmp_path)
    write_status(directory, "ok", whole=False)
    result = run(directory, guard)
    assert result.returncode == WARNING
    assert "truncated" in result.stdout


def test_a_whole_ok_status_is_ok(tmp_path: Path, guard: Path) -> None:
    directory = state(tmp_path)
    write_status(directory, "ok")
    result = run(directory, guard)
    assert result.returncode == OK


def test_the_scratch_file_of_an_in_flight_write_is_not_a_hold(tmp_path: Path, guard: Path) -> None:
    directory = state(tmp_path)
    (directory / "hold" / ".acquacotta.service.new").write_text("{}", encoding="utf-8")
    result = run(directory, guard)
    assert result.returncode == OK


def test_a_hold_with_unreadable_contents_still_counts(tmp_path: Path, guard: Path) -> None:
    # The file's existence is the hold. Losing the ticket number must not lose
    # the alert.
    directory = state(tmp_path)
    (directory / "hold" / "a.service").write_text("not json", encoding="utf-8")
    result = run(directory, guard)
    assert result.returncode == WARNING
    assert "a.service:0h:?" in result.stdout


def test_performance_data_carries_the_counts(tmp_path: Path, guard: Path) -> None:
    directory = state(tmp_path)
    place_hold(directory, age_seconds=7200)
    result = run(directory, guard)
    assert "held=1" in result.stdout
    assert "oldest_hold=" in result.stdout
    assert f";;{STALE_HOLD_SECONDS}" in result.stdout


def test_an_unreadable_hold_directory_is_unknown(tmp_path: Path, guard: Path) -> None:
    # An ABSENT hold directory is the normal state. One that exists and cannot
    # be listed is different: holds may be sitting in it unseen, and OK would
    # be a guess.
    directory = state(tmp_path)
    (directory / "hold").chmod(0o000)
    try:
        result = run(directory, guard)
    finally:
        (directory / "hold").chmod(0o755)
    assert result.returncode == UNKNOWN
    assert "unseen" in result.stdout


def test_no_hold_directory_at_all_is_not_unknown(tmp_path: Path, guard: Path) -> None:
    directory = tmp_path / "fresh"
    directory.mkdir()
    result = run(directory, guard)
    assert result.returncode == OK


# --- precedence, when more than one thing is wrong at once ---


def test_no_guard_outranks_a_stale_hold(tmp_path: Path, no_guard: Path) -> None:
    directory = state(tmp_path)
    place_hold(directory, age_seconds=STALE_HOLD_SECONDS + 3600)
    result = run(directory, no_guard)
    assert result.returncode == CRITICAL
    assert "nothing honours them" in result.stdout
    assert "fleet updates are frozen" not in result.stdout


def test_a_stale_hold_outranks_a_failed_rollback(tmp_path: Path, guard: Path) -> None:
    directory = state(tmp_path)
    place_hold(directory, age_seconds=STALE_HOLD_SECONDS + 3600)
    write_status(directory, "rollback-failed")
    result = run(directory, guard)
    assert result.returncode == CRITICAL
    assert "fleet updates are frozen" in result.stdout


def test_a_failed_rollback_outranks_a_plain_hold(tmp_path: Path, guard: Path) -> None:
    directory = state(tmp_path)
    place_hold(directory)
    write_status(directory, "rollback-failed")
    result = run(directory, guard)
    assert result.returncode == CRITICAL
    assert "rollback did not verify" in result.stdout


def test_a_hold_outranks_a_merely_odd_last_outcome(tmp_path: Path, guard: Path) -> None:
    directory = state(tmp_path)
    place_hold(directory)
    write_status(directory, "could-not-run")
    result = run(directory, guard)
    assert result.returncode == WARNING
    assert "deployer hold(s)" in result.stdout


# --- the stale threshold's boundary ---


def test_a_hold_at_exactly_the_threshold_is_stale(tmp_path: Path, guard: Path) -> None:
    # The comparison is -ge, so the boundary itself is CRITICAL. Pinned, or a
    # change to -gt would pass every other test.
    directory = state(tmp_path)
    place_hold(directory, age_seconds=STALE_HOLD_SECONDS + 1)
    result = run(directory, guard)
    assert result.returncode == CRITICAL
    assert "fleet updates are frozen" in result.stdout


def test_a_hold_just_under_the_threshold_is_only_a_warning(tmp_path: Path, guard: Path) -> None:
    directory = state(tmp_path)
    place_hold(directory, age_seconds=STALE_HOLD_SECONDS - 600)
    result = run(directory, guard)
    assert result.returncode == WARNING
    assert "fleet updates are frozen" not in result.stdout


@pytest.fixture
def broken_systemctl(tmp_path: Path) -> Path:
    """A stub systemctl that fails, as it would with no system manager to ask."""
    path = tmp_path / "systemctl-broken"
    path.write_text(
        '#!/bin/sh\necho "Failed to connect to bus: No such file or directory" >&2\nexit 1\n',
        encoding="utf-8",
    )
    path.chmod(0o755)
    return path


def test_a_failed_systemctl_query_is_unknown_not_a_missing_guard(tmp_path: Path, broken_systemctl: Path) -> None:
    # An empty ExecCondition and a failed query both produce an empty value.
    # Reporting "the guard is missing" for the second sends someone to the
    # wrong file entirely.
    result = run(state(tmp_path), broken_systemctl)
    assert result.returncode == UNKNOWN
    assert "cannot ask systemd" in result.stdout
    assert "Failed to connect to bus" in result.stdout


def test_a_failed_query_is_unknown_even_with_holds_present(tmp_path: Path, broken_systemctl: Path) -> None:
    # Otherwise this would be the CRITICAL "nothing honours them", which is a
    # claim the check cannot actually support here.
    directory = state(tmp_path)
    place_hold(directory)
    result = run(directory, broken_systemctl)
    assert result.returncode == UNKNOWN
    assert "nothing honours them" not in result.stdout


def test_a_state_directory_that_cannot_be_searched_is_unknown(tmp_path: Path, guard: Path) -> None:
    # Readable but not searchable: the hold subdirectory cannot be reached, so
    # "no holds" would be a guess.
    directory = state(tmp_path)
    place_hold(directory)
    directory.chmod(0o444)
    try:
        result = run(directory, guard)
    finally:
        directory.chmod(0o755)
    assert result.returncode == UNKNOWN
    assert "not searchable" in result.stdout


def test_an_outcome_this_check_has_never_heard_of_warns(tmp_path: Path, guard: Path) -> None:
    # Named the other way round on purpose: a list of outcomes to WARN about
    # would read an outcome added to the deployer later as healthy, and the two
    # drifting apart silently is the thing to avoid.
    directory = state(tmp_path)
    write_status(directory, "something-new")
    result = run(directory, guard)
    assert result.returncode == WARNING
    assert "something-new" in result.stdout
