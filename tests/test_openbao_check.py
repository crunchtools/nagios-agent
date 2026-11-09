"""check_openbao.sh: every health code, and the two ways a 200 can still be bad.

The mapping is the part worth testing. OpenBao answers /v1/sys/health with a
STATUS CODE that carries the meaning -- 200 active, 429 standby, 503 sealed,
501 uninitialised -- so the plugin is almost entirely a code-to-Nagios-state
table, and a table is exactly the thing that rots silently when someone edits
one arm of it.

Two cases deserve more than table coverage:

* A 200 with `sealed: true` or `initialized: false` must be CRITICAL, not OK.
  The code alone is reassuring and the body disagrees with it.
* A 200 whose body cannot be parsed must also be CRITICAL. The plugin parses
  with sed because the agent image has neither jq nor python3, and the original
  jq version reported a healthy server as CRITICAL with every field empty. If
  the parse silently yields nothing, the right answer is the loud one.

curl is stubbed on PATH, so this runs anywhere with bash -- no OpenBao, no
network, no CA. The plugin takes OPENBAO_ADDR and OPENBAO_CA from the
environment, which is what makes it testable without touching the real one.
"""

from __future__ import annotations

import os
import subprocess
from pathlib import Path

import pytest

CHECK = Path(__file__).resolve().parents[1] / "rootfs/usr/local/nagios/libexec/check_openbao.sh"

OK = 0
WARNING = 1
CRITICAL = 2
UNKNOWN = 3

HEALTHY = '{"initialized":true,"sealed":false,"standby":false,"version":"2.7.2"}'
SEALED = '{"initialized":true,"sealed":true,"version":"2.7.2"}'
UNINITIALISED = '{"initialized":false,"sealed":true}'


@pytest.fixture
def ca(tmp_path: Path) -> Path:
    """A readable stand-in for the mounted CA. Its contents never matter here."""
    path = tmp_path / "openbao-ca.pem"
    path.write_text("not a real certificate\n", encoding="utf-8")
    return path


def stub_curl(tmp_path: Path, body: str, code: str) -> Path:
    """A curl that prints <body>\\n<code>, which is what -w '\\n%{http_code}' produces."""
    directory = tmp_path / "bin"
    directory.mkdir(exist_ok=True)
    path = directory / "curl"
    path.write_text(
        f"#!/bin/sh\nprintf '%s\\n%s' '{body}' '{code}'\n",
        encoding="utf-8",
    )
    path.chmod(0o755)
    return directory


def run(ca: Path, bindir: Path | None = None, **env: str) -> subprocess.CompletedProcess[str]:
    environ = dict(os.environ)
    environ["OPENBAO_CA"] = str(ca)
    environ["OPENBAO_ADDR"] = "https://127.0.0.1:8200"
    environ["OPENBAO_TIMEOUT"] = "1"
    if bindir is not None:
        environ["PATH"] = f"{bindir}:{environ['PATH']}"
    environ.update(env)
    return subprocess.run(["bash", str(CHECK)], capture_output=True, text=True, env=environ, timeout=30, check=False)


def test_unsealed_and_initialised_is_ok(tmp_path: Path, ca: Path) -> None:
    result = run(ca, stub_curl(tmp_path, HEALTHY, "200"))
    assert result.returncode == OK
    assert "OPENBAO OK" in result.stdout
    assert "2.7.2" in result.stdout


def test_two_hundred_but_sealed_is_critical(tmp_path: Path, ca: Path) -> None:
    """The code says fine and the body says sealed. The body wins."""
    result = run(ca, stub_curl(tmp_path, SEALED, "200"))
    assert result.returncode == CRITICAL
    assert "sealed=true" in result.stdout


def test_two_hundred_but_uninitialised_is_critical(tmp_path: Path, ca: Path) -> None:
    result = run(ca, stub_curl(tmp_path, UNINITIALISED, "200"))
    assert result.returncode == CRITICAL
    assert "initialized=false" in result.stdout


@pytest.mark.parametrize("body", ["", "not json at all", "{}"])
def test_two_hundred_with_an_unparsable_body_is_critical(tmp_path: Path, ca: Path, body: str) -> None:
    """An empty parse must fail loudly: that is how the jq version broke."""
    result = run(ca, stub_curl(tmp_path, body, "200"))
    assert result.returncode == CRITICAL


def test_a_quoted_boolean_does_not_read_as_unsealed(tmp_path: Path, ca: Path) -> None:
    """`"sealed":"false"` is a STRING and must not satisfy the unsealed test.

    This one needs `initialized` to be a real true, or it passes for the wrong
    reason: with no initialized field the check already fails on that arm, and a
    matcher loose enough to accept the quoted string would still look correct.
    Both arms have to be satisfiable for this to measure the boolean matcher.
    """
    body = '{"initialized":true,"sealed":"false","version":"2.7.2"}'
    result = run(ca, stub_curl(tmp_path, body, "200"))
    assert result.returncode == CRITICAL


def test_standby_is_a_warning(tmp_path: Path, ca: Path) -> None:
    result = run(ca, stub_curl(tmp_path, HEALTHY, "429"))
    assert result.returncode == WARNING
    assert "standby" in result.stdout


@pytest.mark.parametrize("code", ["472", "473"])
def test_replication_standby_is_a_warning(tmp_path: Path, ca: Path, code: str) -> None:
    result = run(ca, stub_curl(tmp_path, HEALTHY, code))
    assert result.returncode == WARNING
    assert code in result.stdout


def test_uninitialised_code_is_critical_and_says_why(tmp_path: Path, ca: Path) -> None:
    result = run(ca, stub_curl(tmp_path, UNINITIALISED, "501"))
    assert result.returncode == CRITICAL
    assert "NOT INITIALISED" in result.stdout
    assert "srv-secrets@" in result.stdout


def test_sealed_code_is_critical_and_names_the_unseal_key(tmp_path: Path, ca: Path) -> None:
    """A sealed store is unattended-boot's failure mode, so the output has to
    point at the key file rather than leave the reader guessing."""
    result = run(ca, stub_curl(tmp_path, SEALED, "503"))
    assert result.returncode == CRITICAL
    assert "SEALED" in result.stdout
    assert "unseal.key" in result.stdout


@pytest.mark.parametrize("code", ["000", ""])
def test_no_answer_is_critical(tmp_path: Path, ca: Path, code: str) -> None:
    result = run(ca, stub_curl(tmp_path, "", code))
    assert result.returncode == CRITICAL
    assert "no answer" in result.stdout


def test_an_unexpected_code_is_critical_and_reports_it(tmp_path: Path, ca: Path) -> None:
    result = run(ca, stub_curl(tmp_path, "", "418"))
    assert result.returncode == CRITICAL
    assert "418" in result.stdout


def test_missing_ca_is_unknown_not_critical(tmp_path: Path) -> None:
    """A CA that is not mounted is a monitoring fault, not a store outage.

    Reporting CRITICAL here would page someone to look at OpenBao when the thing
    that is broken is the agent's own volume mount.
    """
    result = run(tmp_path / "definitely-absent.pem")
    assert result.returncode == UNKNOWN
    assert "CA not readable" in result.stdout


def test_perfdata_is_always_present(tmp_path: Path, ca: Path) -> None:
    """Nagios graphs sealed and http, so every exit path has to carry them."""
    for body, code in ((HEALTHY, "200"), (SEALED, "503"), ("", "000"), ("", "418")):
        result = run(ca, stub_curl(tmp_path, body, code))
        assert "| sealed=" in result.stdout, (body, code)
        assert "http=" in result.stdout, (body, code)
