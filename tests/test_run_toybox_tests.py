"""Unit tests for ``scripts.run_toybox_tests``."""

from __future__ import annotations

import runpy
import subprocess
import sys
from collections.abc import Sequence
from pathlib import Path

import pytest

from scripts.run_toybox_tests import (
    CRLF_B,
    NL_B,
    main,
    parse_args,
    run_applet,
    run_functional_suite,
)


def test_run_applet_success_and_failure(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Verify ``run_applet`` handles exit code 0 and non-zero failure.

    Args:
        tmp_path: Pytest temporary directory fixture.
        monkeypatch: Pytest monkeypatch fixture.
    """
    fake_bin = tmp_path / "toybox"
    fake_bin.write_bytes(b"")

    def fake_run_ok(*_args: object, **_kwargs: object) -> subprocess.CompletedProcess[bytes]:
        """Return a simulated successful CompletedProcess.

        Returns:
            CompletedProcess with returncode 0.
        """
        return subprocess.CompletedProcess(args=["toybox"], returncode=0, stdout=b"ok", stderr=b"")

    monkeypatch.setattr(subprocess, "run", fake_run_ok)
    res = run_applet(fake_bin, ["echo", "hi"])
    assert res.stdout == b"ok"

    def fake_run_fail(*_args: object, **_kwargs: object) -> subprocess.CompletedProcess[bytes]:
        """Return a simulated failing CompletedProcess.

        Returns:
            CompletedProcess with returncode 1.
        """
        return subprocess.CompletedProcess(
            args=["toybox"], returncode=1, stdout=b"", stderr=b"boom"
        )

    monkeypatch.setattr(subprocess, "run", fake_run_fail)
    with pytest.raises(RuntimeError, match="failed with exit code 1: boom"):
        run_applet(fake_bin, ["false"])


def test_run_functional_suite_and_cli(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """Verify ``run_functional_suite``, CLI ``main()``, and ``__main__`` entry point.

    Args:
        tmp_path: Pytest temporary directory fixture.
        monkeypatch: Pytest monkeypatch fixture.
        capsys: Pytest stdout/stderr capture fixture.
    """
    fake_bin = tmp_path / "toybox"
    fake_bin.write_bytes(b"binary")

    def simulated_applet(
        _bin: Path,
        args: Sequence[str],
        *,
        stdin_data: bytes | None = None,
        cwd: Path | None = None,
        emulator: Sequence[str] = (),
    ) -> subprocess.CompletedProcess[bytes]:
        """Simulate Toybox applet responses for ``run_functional_suite``.

        Args:
            _bin: Ignored binary path.
            args: Applet arguments.
            stdin_data: Optional stdin bytes.
            cwd: Optional working directory.
            emulator: Optional emulator command sequence.

        Returns:
            Simulated ``subprocess.CompletedProcess[bytes]``.
        """
        _ = (stdin_data, cwd, emulator)
        cmd = args[0]
        outputs: dict[str, bytes] = {
            "sort": NL_B.join([b"apple", b"apple", b"banana", b"cherry", b""]),
            "uniq": NL_B.join([b"apple", b"banana", b"cherry", b""]),
            "wc": b"3" + NL_B,
            "grep": b"banana" + CRLF_B,
            "sed": b"blueberry" + NL_B,
            "tr": b"HELLO" + NL_B,
            "cut": b"two" + NL_B,
            "rev": b"dcba" + NL_B,
            "head": NL_B.join([b"apple", b"banana", b""]),
            "tail": b"cherry" + NL_B,
            "md5sum": b"900150983cd24fb0d6963f7d28e17f72  -" + NL_B,
            "sha1sum": b"a9993e364706816aba3e25717850c26c9cd0d89d  -" + NL_B,
            "sha256sum": (
                b"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad  -" + NL_B
            ),
            "crc32": b"cbf43926" + NL_B,
            "base32": b"MZXW6===" + NL_B,
            "xxd": b"4869" + NL_B,
            "bc": b"144" + NL_B,
            "awk": b"42" + NL_B,
            "cmp": b"",
            "cat": b"payload-data" + NL_B,
            "ls": b"a.txt b.txt" + NL_B,
            "gzip": b"gzbytes",
            "zcat": b"payload-data" + NL_B,
        }
        if cmd == "base64":
            out = b"toybox-win" if "-d" in args else b"dG95Ym94LXdpbg==" + NL_B
            return subprocess.CompletedProcess(args=args, returncode=0, stdout=out, stderr=b"")
        if cmd == "mkdir":
            Path(args[-1]).mkdir(parents=True, exist_ok=True)
            return subprocess.CompletedProcess(args=args, returncode=0, stdout=b"", stderr=b"")
        if cmd == "cp":
            Path(args[2]).write_bytes(Path(args[1]).read_bytes())
            return subprocess.CompletedProcess(args=args, returncode=0, stdout=b"", stderr=b"")
        if cmd == "tar":
            if "-cf" in args:
                Path(args[2]).write_bytes(b"tarbytes")
                return subprocess.CompletedProcess(args=args, returncode=0, stdout=b"", stderr=b"")
            if "-tf" in args:
                return subprocess.CompletedProcess(
                    args=args,
                    returncode=0,
                    stdout=NL_B.join([b"a.txt", b"b.txt", b""]),
                    stderr=b"",
                )
            dest = Path(args[-1])
            (dest / "a.txt").write_bytes(b"payload-data" + NL_B)
            return subprocess.CompletedProcess(args=args, returncode=0, stdout=b"", stderr=b"")
        if cmd == "rm":
            for target in args[2:]:
                p = Path(target)
                for child in list(p.glob("*")):
                    child.unlink()
                p.rmdir()
            return subprocess.CompletedProcess(args=args, returncode=0, stdout=b"", stderr=b"")

        return subprocess.CompletedProcess(args=args, returncode=0, stdout=outputs[cmd], stderr=b"")

    monkeypatch.setattr("scripts.run_toybox_tests.run_applet", simulated_applet)
    run_functional_suite(fake_bin)

    parsed = parse_args(["--toybox", str(fake_bin), "--emulator", "wine"])
    assert parsed.toybox == fake_bin
    assert parsed.emulator == "wine"

    # CLI success (with and without --emulator)
    assert main(["--toybox", str(fake_bin)]) == 0
    assert main(["--toybox", str(fake_bin), "--emulator", "wine"]) == 0

    # CLI missing binary
    missing_bin = tmp_path / "missing_toybox"
    assert main(["--toybox", str(missing_bin)]) == 1
    assert "toybox binary not found" in capsys.readouterr().err

    # CLI suite failure
    def raise_fail(_bin: Path, *, emulator: Sequence[str] = ()) -> None:
        """Raise an AssertionError to test CLI error reporting.

        Args:
            _bin: Ignored binary path.
            emulator: Optional emulator command sequence.

        Raises:
            AssertionError: Always raised.
        """
        _ = emulator
        raise AssertionError("suite assertion failed")

    monkeypatch.setattr("scripts.run_toybox_tests.run_functional_suite", raise_fail)
    assert main(["--toybox", str(fake_bin)]) == 1
    assert "Toybox functional test failure" in capsys.readouterr().err

    # __main__ execution with missing binary
    old_argv = sys.argv
    sys.argv = ["run_toybox_tests.py", "--toybox", str(missing_bin)]
    try:
        script_path = Path(__file__).resolve().parent.parent / "scripts" / "run_toybox_tests.py"
        with pytest.raises(SystemExit) as exc_info:
            runpy.run_path(str(script_path), run_name="__main__")
        assert exc_info.value.code == 1
    finally:
        sys.argv = old_argv
    capsys.readouterr()
