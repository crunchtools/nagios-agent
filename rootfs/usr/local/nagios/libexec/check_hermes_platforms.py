#!/usr/bin/env python3
"""Verify the Hermes gateway's messaging platforms can still hear.

Kagetora went deaf on Matrix for three and a half days and every check we had
stayed green. A connection timeout to the Trentina /matrix proxy
was misclassified by the adapter as a permanent auth error; it stopped its sync
loop and never retried. Outbound sends kept working, so cron alerts still
arrived on schedule. The container was running, its memory was normal, and
gateway_state.json still read "connected" -- that per-platform record is
written on state CHANGE and never refreshed, so a frozen snapshot of past
health is byte-identical to present health.

The lesson is that "connected" is a claim, not evidence. This check
corroborates the claim against independent facts:

  1. the writer process named in the record still exists, and is the SAME
     process: start_time is compared against /proc field 22, so a recycled PID
     cannot pose as a living writer. (Verified necessary: container pid 49 was
     live again as an unrelated worker, so a bare existence test passed.)
  2. the adapter's own log does not end on a terminal sync-stop.

Either one alone would have missed this outage. (1) catches a writer that
died; (2) catches a writer that stayed alive but stopped listening, which is
what actually happened and is invisible to every process-level probe.

No timestamp in gateway_state.json is a heartbeat. Both the per-platform
updated_at and the top-level one are written on events, so their age says
nothing about health; the top-level age is perfdata, never an alert.

HOW IT RUNS: inside the Hermes container, via check_hermes_exec.sh and the
podman exec socket. The data dir is 0700 and its logs hold conversations, so it
never leaves its container; only this verdict does. Inside the container the
writer pids in gateway_state.json are this namespace's pids, and the exec
succeeding is itself proof the container runs. Python standard library only:
the Hermes image has python3 but no grep, sed or awk. (It replaced a bash
script run as root on the host by hermes-probe.timer.)

Usage: check_hermes_platforms.py [data_dir] [platforms]
  data_dir   Hermes home inside the container (default /app/.hermes)
  platforms  comma-separated platforms that must be connected (default matrix,webhook)

Exit: 0 OK, 2 CRITICAL, 3 UNKNOWN
"""

import json
import re
import sys
import time
from datetime import datetime
from pathlib import Path

OK, CRITICAL, UNKNOWN = 0, 2, 3
STOP = re.compile(r"Matrix: (permanent auth error|disconnected)|Matrix: .*stopping sync")
START = re.compile(r"Matrix: initial sync complete")
STAMP_LEN = len("YYYY-MM-DD HH:MM:SS")  # log lines start with this timestamp
STARTTIME_AFTER_COMM = 19  # /proc/<pid>/stat field 22, counted after the ") " that ends comm
MAX_DETAIL = 200  # Hermes's own error text is echoed, but never unbounded


def clip(text):
    text = " ".join(str(text).split())
    return text if len(text) <= MAX_DETAIL else text[: MAX_DETAIL - 3] + "..."


def writer_fault(proc, pid, start):
    """Why the recorded writer is not the live writer, or None when it is."""
    if pid is None:
        return "no writer_pid recorded"
    try:
        stat = (Path(proc) / str(pid) / "stat").read_text()
    except FileNotFoundError:
        return f"writer pid {pid} is gone"
    except OSError as e:
        return f"writer pid {pid} cannot be checked ({e.strerror})"
    if start is None:
        return None  # nothing to compare; liveness is enough
    actual = stat.rsplit(") ", 1)[1].split()[STARTTIME_AFTER_COMM]
    if actual != str(start):
        return f"writer pid {pid} was recycled (start_time {actual}, expected {start})"
    return None


def last_markers(log_dir):
    """Newest stop and start timestamps across the logs, streamed line by line.

    Reads the rotated copies too (errors.log.1, gateway.log.2, ...), so a stop
    whose marker rotated out of the current file is still seen. Hermes keeps a
    few rotations of a few MB each, so the scan stays bounded, and nothing but
    the two newest stamps is kept in memory.

    Returns (last_stop, last_start, problem): problem names logs that could not
    be read, or says there were none. Missing evidence is not health.
    """
    last_stop = last_start = ""
    paths = sorted(p for name in ("errors.log", "gateway.log") for p in Path(log_dir).glob(name + "*"))
    unreadable = []
    for path in paths:
        try:
            with open(path, errors="replace") as log:
                for line in log:
                    if STOP.search(line):
                        last_stop = max(last_stop, line[:STAMP_LEN])
                    elif START.search(line):
                        last_start = max(last_start, line[:STAMP_LEN])
        except OSError as e:
            unreadable.append(f"{path.name} ({e.strerror})")
    problem = None
    if not paths:
        problem = f"no errors.log or gateway.log in {log_dir}"
    elif unreadable:
        problem = "cannot read " + ", ".join(unreadable)
    return last_stop, last_start, problem


def updated_age(state, now):
    """Seconds since the top-level updated_at, or -1. Perfdata only, never an alert."""
    stamp = state.get("updated_at")
    if not isinstance(stamp, str):
        return -1
    try:
        return max(0, int(now - datetime.fromisoformat(stamp.replace("Z", "+00:00")).timestamp()))
    except ValueError:
        return -1


def platform_fault(name, rec, proc):
    """Why one platform's "connected" claim does not hold, or None when it does."""
    if not isinstance(rec, dict):
        return f"{name} missing from gateway_state"
    if rec.get("state") != "connected":
        code, err = rec.get("error_code"), rec.get("error_message")
        detail = (f" [{clip(code)}]" if code else "") + (f": {clip(err)}" if err else "")
        return f"{name} is '{clip(rec.get('state') or 'unknown')}'{detail}"
    fault = writer_fault(proc, rec.get("writer_pid"), rec.get("writer_start_time"))
    return f"{name} claims connected but {fault}" if fault else None


def matrix_sync(log_dir):
    """(fault, note) for the Matrix sync loop.

    The failure that started all this: the adapter announces a terminal stop
    and then never syncs again. A (re)connect always logs "initial sync
    complete", so a stop newer than the newest start means the loop is down
    now; comparing the two clears itself on restart.
    """
    last_stop, last_start, problem = last_markers(log_dir)
    if problem:
        return f"matrix sync loop cannot be verified: {problem}", ""
    if last_stop and (not last_start or last_stop > last_start):
        return f"matrix sync loop stopped at {last_stop} and has not resynced", ""
    return None, (f", matrix synced {last_start}" if last_stop else "")


def check(data_dir, platforms, proc="/proc", now=None):
    """Judge the gateway and each platform.

    data_dir   Hermes home holding gateway_state.json and logs/
    platforms  platform names that must be connected, e.g. ["matrix", "webhook"]
    proc       procfs root the writer pids are looked up in (tests point it elsewhere)
    now        epoch seconds for the updated_at perfdata (defaults to the clock)

    Returns (exit_code, message): 0 OK, 2 CRITICAL, 3 UNKNOWN, and one Nagios
    status line with perfdata.
    """
    state_path = Path(data_dir) / "gateway_state.json"
    try:
        state = json.loads(state_path.read_text())
    except OSError:
        return UNKNOWN, f"UNKNOWN - cannot read {state_path}"
    except ValueError:
        return UNKNOWN, f"UNKNOWN - {state_path} is not valid JSON"

    gw_state = state.get("gateway_state")
    if not gw_state:
        return UNKNOWN, f"UNKNOWN - no gateway_state field in {state_path}"
    if gw_state != "running":
        reason = state.get("exit_reason")
        return CRITICAL, f"CRITICAL - Hermes gateway state is '{clip(gw_state)}'" + (
            f" (exit_reason: {clip(reason)})" if reason else ""
        )

    records = state.get("platforms") or {}
    faults = {p: platform_fault(p, records.get(p), proc) for p in platforms}
    crit = [f for f in faults.values() if f]
    good = [p for p, f in faults.items() if not f]
    sync_note = ""
    if "matrix" in platforms:
        fault, sync_note = matrix_sync(Path(data_dir) / "logs")
        if fault:
            crit.append(fault)
            good = [p for p in good if p != "matrix"]

    age = updated_age(state, time.time() if now is None else now)
    perf = f"platforms_ok={len(good)};;;0;{len(platforms)} gateway_updated_age={age}s;;;0"
    if crit:
        return CRITICAL, "CRITICAL - " + "; ".join(crit) + f"; | {perf}"
    verified = f"{len(good)}/{len(platforms)} platforms connected and verified: {' '.join(good)}"
    return OK, f"OK - {verified}{sync_note} | {perf}"


def main(argv):
    args = [*argv[1:], None, None]
    data_dir = args[0] or "/app/.hermes"
    platforms = [p.strip() for p in (args[1] or "matrix,webhook").split(",") if p.strip()]
    code, message = check(data_dir, platforms)
    print(message)
    return code


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv))
    except Exception as e:  # a crashed probe must page, not read as WARNING (exit 1)
        print(f"CRITICAL - check_hermes_platforms.py crashed: {type(e).__name__}: {e}")
        sys.exit(CRITICAL)
