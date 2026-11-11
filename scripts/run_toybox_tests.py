#!/usr/bin/env python3
"""Functional integration test runner for the compiled ``toybox`` binary.

Exercises Toybox applets across text processing, checksums, encoding,
compression/archives, filesystem operations, and mathematical utilities.
"""

from __future__ import annotations

import argparse
import subprocess
import sys
import tempfile
from collections.abc import Sequence
from pathlib import Path

NL_B: bytes = bytes([10])
CRLF_B: bytes = bytes([13, 10])


def run_applet(
    toybox_bin: Path,
    args: Sequence[str],
    *,
    stdin_data: bytes | None = None,
    cwd: Path | None = None,
    emulator: Sequence[str] = (),
) -> subprocess.CompletedProcess[bytes]:
    """Execute a Toybox applet and return the completed process result.

    Args:
        toybox_bin: Path to the compiled ``toybox`` or ``toybox.exe`` binary.
        args: Applet name and arguments to pass to ``toybox``.
        stdin_data: Optional bytes to pipe to standard input.
        cwd: Optional working directory for the subprocess.
        emulator: Optional cross-compiling emulator command prefix (e.g. ``["wine"]``).

    Returns:
        ``subprocess.CompletedProcess[bytes]`` containing stdout, stderr, and returncode.

    Raises:
        RuntimeError: If the command exits with a non-zero status code.
    """
    cmd = [*emulator, str(toybox_bin), *args]
    res = subprocess.run(
        cmd,
        input=stdin_data,
        cwd=cwd,
        capture_output=True,
        check=False,
    )
    if res.returncode != 0:
        err_msg = res.stderr.decode("utf-8", errors="replace").strip()
        raise RuntimeError(f"Command {cmd} failed with exit code {res.returncode}: {err_msg}")
    return res


def run_functional_suite(
    toybox_bin: Path,
    *,
    emulator: Sequence[str] = (),
) -> None:
    """Execute the end-to-end Toybox functional verification suite.

    Args:
        toybox_bin: Path to the compiled ``toybox`` binary.
        emulator: Optional cross-compiling emulator command prefix (e.g. ``["wine"]``).
    """
    resolved_bin = toybox_bin.resolve()

    def _run(
        args: Sequence[str],
        *,
        stdin_data: bytes | None = None,
        cwd: Path | None = None,
    ) -> subprocess.CompletedProcess[bytes]:
        """Invoke ``run_applet`` with the configured ``resolved_bin`` and ``emulator``.

        Args:
            args: Applet name and arguments to pass to ``toybox``.
            stdin_data: Optional bytes to pipe to standard input.
            cwd: Optional working directory for the subprocess.

        Returns:
            ``subprocess.CompletedProcess[bytes]`` from ``run_applet``.
        """
        return run_applet(
            resolved_bin,
            args,
            stdin_data=stdin_data,
            cwd=cwd,
            emulator=emulator,
        )

    # 1. Text processing (sort, uniq, wc, grep, sed, tr, cut, rev, head, tail)
    sample_lines = NL_B.join([b"banana", b"apple", b"cherry", b"apple", b""])
    expected_sorted = NL_B.join([b"apple", b"apple", b"banana", b"cherry", b""])
    sorted_out = _run(["sort"], stdin_data=sample_lines).stdout.replace(CRLF_B, NL_B)
    assert sorted_out == expected_sorted

    expected_uniq = NL_B.join([b"apple", b"banana", b"cherry", b""])
    uniq_out = _run(["uniq"], stdin_data=sorted_out).stdout.replace(CRLF_B, NL_B)
    assert uniq_out == expected_uniq

    wc_out = _run(["wc", "-l"], stdin_data=uniq_out).stdout.decode("utf-8").strip()
    assert wc_out.startswith("3")

    grep_out = _run(["grep", "^b"], stdin_data=uniq_out).stdout.replace(CRLF_B, NL_B)
    assert grep_out == b"banana" + NL_B

    sed_out = _run(["sed", "s/banana/blueberry/"], stdin_data=grep_out).stdout.replace(CRLF_B, NL_B)
    assert sed_out == b"blueberry" + NL_B

    tr_out = _run(["tr", "a-z", "A-Z"], stdin_data=b"hello" + NL_B).stdout.replace(CRLF_B, NL_B)
    assert tr_out == b"HELLO" + NL_B

    cut_out = _run(["cut", "-d:", "-f2"], stdin_data=b"one:two:three" + NL_B).stdout.replace(
        CRLF_B, NL_B
    )
    assert cut_out == b"two" + NL_B

    rev_out = _run(["rev"], stdin_data=b"abcd" + NL_B).stdout.replace(CRLF_B, NL_B)
    assert rev_out == b"dcba" + NL_B

    head_out = _run(["head", "-n", "2"], stdin_data=uniq_out).stdout.replace(CRLF_B, NL_B)
    assert head_out == NL_B.join([b"apple", b"banana", b""])

    tail_out = _run(["tail", "-n", "1"], stdin_data=uniq_out).stdout.replace(CRLF_B, NL_B)
    assert tail_out == b"cherry" + NL_B

    # 2. Checksums & Encoding (md5sum, sha1sum, sha256sum, crc32, base64, base32, xxd)
    md5_out = _run(["md5sum"], stdin_data=b"abc").stdout.decode("utf-8").strip()
    assert md5_out.startswith("900150983cd24fb0d6963f7d28e17f72")

    sha1_out = _run(["sha1sum"], stdin_data=b"abc").stdout.decode("utf-8").strip()
    assert sha1_out.startswith("a9993e364706816aba3e25717850c26c9cd0d89d")

    sha256_out = _run(["sha256sum"], stdin_data=b"abc").stdout.decode("utf-8").strip()
    assert sha256_out.startswith("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")

    crc_out = _run(["crc32"], stdin_data=b"123456789").stdout.decode("utf-8").strip()
    assert crc_out == "cbf43926"

    b64_enc = _run(["base64"], stdin_data=b"toybox-win").stdout.strip()
    assert b64_enc == b"dG95Ym94LXdpbg=="
    b64_dec = _run(["base64", "-d"], stdin_data=b64_enc + NL_B).stdout
    assert b64_dec == b"toybox-win"

    b32_enc = _run(["base32"], stdin_data=b"foo").stdout.strip()
    assert b32_enc == b"MZXW6==="

    xxd_enc = _run(["xxd", "-p"], stdin_data=b"Hi").stdout.strip()
    assert xxd_enc == b"4869"

    # 3. Math & Awk (bc, awk)
    bc_out = _run(["bc"], stdin_data=b"12 * 12" + NL_B).stdout.decode("utf-8").strip()
    assert bc_out == "144"

    awk_in = NL_B.join([b"10", b"20", b"12", b""])
    awk_out = (
        _run(["awk", "{ sum += $1 } END { print sum }"], stdin_data=awk_in)
        .stdout.decode("utf-8")
        .strip()
    )
    assert awk_out == "42"

    # 4. Filesystem, Compression & Archives (mkdir, cp, cmp, cat, ls, gzip, zcat, tar, rm)
    payload = b"payload-data" + NL_B
    with tempfile.TemporaryDirectory() as tmp_str:
        tmp_dir = Path(tmp_str)
        sub_dir = tmp_dir / "work"
        _run(["mkdir", "-p", str(sub_dir)])
        assert sub_dir.is_dir()

        file_a = sub_dir / "a.txt"
        file_a.write_bytes(payload)

        file_b = sub_dir / "b.txt"
        _run(["cp", str(file_a), str(file_b)])
        assert file_b.read_bytes() == payload

        _run(["cmp", str(file_a), str(file_b)])

        cat_out = _run(["cat", str(file_b)]).stdout
        assert cat_out == payload

        ls_out = _run(["ls", str(sub_dir)]).stdout.decode("utf-8").split()
        assert "a.txt" in ls_out and "b.txt" in ls_out

        # gzip / zcat round-trip
        gz_data = _run(["gzip", "-c", str(file_a)]).stdout
        unz_data = _run(["zcat"], stdin_data=gz_data).stdout
        assert unz_data == payload

        # tar create / list / extract
        tar_path = tmp_dir / "archive.tar"
        _run(["tar", "-cf", str(tar_path), "a.txt", "b.txt"], cwd=sub_dir)
        assert tar_path.is_file()

        tar_list = _run(["tar", "-tf", str(tar_path)]).stdout.decode("utf-8").splitlines()
        assert "a.txt" in tar_list and "b.txt" in tar_list

        extract_dir = tmp_dir / "extracted"
        _run(["mkdir", str(extract_dir)])
        _run(["tar", "-xf", str(tar_path), "-C", str(extract_dir)])
        assert (extract_dir / "a.txt").read_bytes() == payload

        _run(["rm", "-rf", str(sub_dir), str(extract_dir)])
        assert not sub_dir.exists()


def parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    """Parse CLI arguments for ``run_toybox_tests.py``.

    Args:
        argv: Optional sequence of CLI arguments (defaults to ``sys.argv[1:]``).

    Returns:
        Parsed ``argparse.Namespace``.
    """
    parser = argparse.ArgumentParser(
        description="Run end-to-end functional integration tests against a compiled toybox binary."
    )
    parser.add_argument(
        "--toybox",
        type=Path,
        required=True,
        help="Path to the compiled toybox binary.",
    )
    parser.add_argument(
        "--emulator",
        type=str,
        default="",
        help="Optional cross-compiling emulator command (e.g. wine).",
    )
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    """Run the Toybox functional test suite CLI entry point.

    Args:
        argv: Optional sequence of CLI arguments.

    Returns:
        Exit status code (``0`` on success, ``1`` on failure).
    """
    args = parse_args(argv)
    if not args.toybox.is_file():
        print(f"Error: toybox binary not found: {args.toybox}", file=sys.stderr)
        return 1
    emulator_parts = [p for p in str(args.emulator).split(";") if p]
    try:
        run_functional_suite(args.toybox, emulator=emulator_parts)
    except (AssertionError, RuntimeError) as exc:
        print(f"Toybox functional test failure: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
