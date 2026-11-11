#!/usr/bin/env python3
"""Deterministic build-time header and configuration generator for Toybox.

This module replaces Toybox's POSIX shell and host-compiler scripts
(``scripts/genconfig.sh``, ``scripts/make.sh``, ``scripts/mkflags.c``, and
``scripts/kconfig.c``) with a pure Python implementation that generates:
  - ``generated/config.h``
  - ``generated/newtoys.h``
  - ``generated/flags.h``
  - ``generated/globals.h``
  - ``generated/tags.h``
  - ``generated/help.h``
  - ``enabled_sources.cmake`` (list of active ``main.c``, ``lib/*.c``, and ``toys/*/*.c``)

All headers and metadata are emitted into an out-of-tree build directory so
zero ``.c`` or ``.h`` files are modified in ``../toybox`` or stored in
``toybox-windows``.
"""

from __future__ import annotations

import argparse
import dataclasses
import re
import sys
from collections.abc import Mapping, Sequence
from pathlib import Path

# Core library sources that are portable across Windows (MSVC), DOS (OpenWatcom), and POSIX
CORE_LIB_SOURCES: tuple[str, ...] = (
    "lib/args.c",
    "lib/commas.c",
    "lib/deflate.c",
    "lib/dirtree.c",
    "lib/elf.c",
    "lib/env.c",
    "lib/hash.c",
    "lib/lib.c",
    "lib/llist.c",
    "lib/net.c",
    "lib/password.c",
    "lib/portability.c",
    "lib/tty.c",
    "lib/utf8.c",
    "lib/xwrap.c",
)

# Portable applets enabled for both Windows (MSVC) and 32-bit DOS (OpenWatcom)
COMMON_ENABLED_SYMBOLS: tuple[str, ...] = (
    # Global Toybox settings
    "TOYBOX",
    "TOYBOX_LSM_NONE",
    "TOYBOX_FLOAT",
    "TOYBOX_HELP",
    "TOYBOX_HELP_DASHDASH",
    "TOYBOX_NORECURSE",
    # toys/posix
    "BASENAME",
    "CAL",
    "CAT",
    "CHGRP",
    "CHOWN",
    "CHMOD",
    "CKSUM",
    "CRC32",
    "CMP",
    "COMM",
    "CP",
    "MV",
    "INSTALL",
    "CPIO",
    "CUT",
    "DATE",
    "DD",
    "DIRNAME",
    "DU",
    "ECHO",
    "ENV",
    "EXPAND",
    "FALSE",
    "FILE",
    "FIND",
    "FOLD",
    "GREP",
    "EGREP",
    "FGREP",
    "HEAD",
    "ID",
    "GROUPS",
    "LOGNAME",
    "WHOAMI",
    "LINK",
    "LN",
    "LS",
    "MKDIR",
    "MKFIFO",
    "NICE",
    "NL",
    "OD",
    "PASTE",
    "PATCH",
    "PRINTF",
    "PWD",
    "RM",
    "RMDIR",
    "SED",
    "SLEEP",
    "SORT",
    "SPLIT",
    "STRINGS",
    "TAIL",
    "TAR",
    "TEE",
    "TEST",
    "TEST_GLUE",
    "TIME",
    "TOUCH",
    "TRUE",
    "TSORT",
    "TTY",
    "UNAME",
    "ARCH",
    "UNIQ",
    "UNLINK",
    "UUDECODE",
    "UUENCODE",
    "WC",
    "XARGS",
    # toys/lsb
    "GZIP",
    "GUNZIP",
    "ZCAT",
    "HOSTNAME",
    "DNSDOMAINNAME",
    "MD5SUM",
    "SHA1SUM",
    "SHA224SUM",
    "SHA256SUM",
    "SHA384SUM",
    "SHA512SUM",
    "MKTEMP",
    "SEQ",
    "SYNC",
    # toys/other
    "ASCII",
    "UNICODE",
    "BASE64",
    "BASE32",
    "BZCAT",
    "BUNZIP2",
    "CLEAR",
    "COUNT",
    "DOS2UNIX",
    "UNIX2DOS",
    "FACTOR",
    "FMT",
    "FSYNC",
    "GETOPT",
    "HD",
    "HELP",
    "HEXEDIT",
    "MCOOKIE",
    "MKPASSWD",
    "MOUNTPOINT",
    "PRINTENV",
    "PWGEN",
    "READELF",
    "READLINK",
    "REALPATH",
    "RESET",
    "REV",
    "SHA3SUM",
    "SHRED",
    "SHUF",
    "STAT",
    "TAC",
    "TRUNCATE",
    "TS",
    "USLEEP",
    "UUIDGEN",
    "WHICH",
    "XXD",
    "YES",
    # toys/pending (portable text/math/archive utilities)
    "AWK",
    "BC",
    "CSPLIT",
    "DIFF",
    "EXPR",
    "HEXDUMP",
    "MORE",
    "TR",
    "XZCAT",
)

# Additional applets enabled on Windows (MSVC) and POSIX hosts (requiring sockets/processes)
WINDOWS_EXTRA_SYMBOLS: tuple[str, ...] = (
    "DF",
    "KILL",
    "KILLALL",
    "KILLALL5",
    "LOGGER",
    "NOHUP",
    "PIDOF",
    "RENICE",
    "SETSID",
    "TIMEOUT",
    "WATCH",
    "FTPGET",
    "FTPPUT",
    "HTTPD",
    "NETCAT",
    "NC",
    # "SNTP",
    "WGET",
    "VI",
)

DEFAULT_INT_SYMBOLS: Mapping[str, int] = {
    "TOYBOX_UID_SYS": 100,
    "TOYBOX_UID_USR": 500,
}

CONFIG_RE = re.compile(r"^\s*config\s+([A-Z0-9_]+)\s*$", re.MULTILINE)
CFG_USE_SKIP_RE = re.compile(r"\b(?:CFG|USE|SKIP)_([A-Z0-9_]+)\b")
TOY_LINE_RE = re.compile(r"^USE_([A-Z0-9_]+)\((NEW|OLD)TOY\(([^,]+),\s*(.+),\s*([^,]+)\)\)$")
FOR_DEF_RE = re.compile(r"^#define\s+FOR_([A-Za-z0-9_]+)")
TAGGED_ARRAY_START_RE = re.compile(r"TAGGED_ARRAY\(([^,]+),")
TAG_ITEM_RE = re.compile(r'\{\s*"([^"]*)"')
NON_IDENT_RE = re.compile(r"[^A-Za-z0-9_]")
MACRO_IN_OPT_RE = re.compile(r'(USE|SKIP)_([A-Z0-9_]+)\("([^"]*)"\)')
QUOTED_STR_RE = re.compile(r'"([^"]*)"')


@dataclasses.dataclass(frozen=True)
class ToyEntry:
    """Parsed representation of a ``USE_*(NEWTOY(...))`` or ``USE_*(OLDTOY(...))`` macro line.

    Attributes:
        guard_sym: The ``USE_<guard_sym>`` configuration symbol name.
        kind: Either ``"NEW"`` or ``"OLD"``.
        name: The command/applet name (first argument to ``NEWTOY``/``OLDTOY``).
        raw_middle: Raw option string (for ``NEWTOY``) or target applet name (for ``OLDTOY``).
        flags_expr: Toybox ``TOYFLAG_*`` expression string.
        raw_line: Original unmodified macro line from the source file.
        source_rel: Relative path of the source file (e.g. ``"toys/posix/cat.c"``).
    """

    guard_sym: str
    kind: str
    name: str
    raw_middle: str
    flags_expr: str
    raw_line: str
    source_rel: str


@dataclasses.dataclass
class FlagNode:
    """Single short option or bare long option parsed by ``digest_optstring``.

    Attributes:
        command: Single-character short option string, or ``None`` for bare longopts.
        lopt: List of attached long option names (with ``-`` normalized to ``_``).
    """

    command: str | None
    lopt: list[str]


def get_toy_source_files(toybox_dir: Path) -> list[Path]:
    """Return sorted ``toys/*/*.c`` source paths within ``toybox_dir``.

    Args:
        toybox_dir: Path to the upstream ``toybox`` source directory.

    Returns:
        Sorted list of ``Path`` objects for all ``toys/*/*.c`` files.
    """
    toys_root = toybox_dir / "toys"
    if not toys_root.is_dir():
        return []
    return sorted(toys_root.glob("*/*.c"))


def collect_all_config_symbols(toybox_dir: Path) -> list[str]:
    """Collect all Kconfig and ``CFG_``/``USE_``/``SKIP_`` symbol names in ``toybox_dir``.

    Args:
        toybox_dir: Path to the upstream ``toybox`` source directory.

    Returns:
        Sorted list of unique configuration symbol names.
    """
    symbols: set[str] = set(COMMON_ENABLED_SYMBOLS) | set(WINDOWS_EXTRA_SYMBOLS)
    symbols.update(DEFAULT_INT_SYMBOLS.keys())

    config_in = toybox_dir / "Config.in"
    if config_in.is_file():
        text = config_in.read_text(encoding="utf-8", errors="replace")
        symbols.update(CONFIG_RE.findall(text))
        symbols.update(CFG_USE_SKIP_RE.findall(text))

    scan_paths: list[Path] = []
    scan_paths.extend(sorted(toybox_dir.glob("*.h")))
    scan_paths.extend(sorted(toybox_dir.glob("*.c")))
    lib_dir = toybox_dir / "lib"
    if lib_dir.is_dir():
        scan_paths.extend(sorted(lib_dir.glob("*.h")))
        scan_paths.extend(sorted(lib_dir.glob("*.c")))
    scan_paths.extend(get_toy_source_files(toybox_dir))

    for path in scan_paths:
        text = path.read_text(encoding="utf-8", errors="replace")
        symbols.update(CONFIG_RE.findall(text))
        symbols.update(CFG_USE_SKIP_RE.findall(text))

    return sorted(symbols)


def build_default_config_map(
    all_symbols: Sequence[str],
    *,
    target_dos: bool = False,
) -> dict[str, int | bool]:
    """Construct the symbol configuration map for Windows or 32-bit DOS.

    Args:
        all_symbols: Sequence of all known Toybox configuration symbol names.
        target_dos: If ``True``, use the single-tasking 32-bit DOS profile;
            otherwise use the Windows/MSVC profile.

    Returns:
        Dictionary mapping symbol names to ``bool`` (for boolean toggles) or
        ``int`` (for integer configuration values like ``TOYBOX_UID_SYS``).
    """
    enabled_set = set(COMMON_ENABLED_SYMBOLS)
    if not target_dos:
        enabled_set.update(WINDOWS_EXTRA_SYMBOLS)

    cfg: dict[str, int | bool] = {}
    for sym in all_symbols:
        if sym in DEFAULT_INT_SYMBOLS:
            cfg[sym] = DEFAULT_INT_SYMBOLS[sym]
        else:
            cfg[sym] = sym in enabled_set
    return cfg


def generate_config_h(config_map: Mapping[str, int | bool]) -> str:
    """Generate the contents of ``generated/config.h``.

    Args:
        config_map: Mapping of configuration symbol names to boolean or integer values.

    Returns:
        Complete C header text for ``generated/config.h``.
    """
    nl = chr(10)
    lines: list[str] = [
        "/* Generated by toybox-windows generate_toybox_headers.py */",
        "#ifndef TOYBOX_GENERATED_CONFIG_H",
        "#define TOYBOX_GENERATED_CONFIG_H",
        "",
    ]
    for sym in sorted(config_map.keys()):
        val = config_map[sym]
        if isinstance(val, bool):
            if val:
                lines.append(f"#define CFG_{sym} 1")
                lines.append(f"#define USE_{sym}(...) __VA_ARGS__")
                lines.append(f"#define SKIP_{sym}(...)")
            else:
                lines.append(f"#define CFG_{sym} 0")
                lines.append(f"#define USE_{sym}(...)")
                lines.append(f"#define SKIP_{sym}(...) __VA_ARGS__")
        else:
            lines.append(f"#define CFG_{sym} {val}")
            lines.append(f"#define USE_{sym}(...) __VA_ARGS__")
            lines.append(f"#define SKIP_{sym}(...)")
    lines.append("")
    lines.append("#endif /* TOYBOX_GENERATED_CONFIG_H */")
    lines.append("")
    return nl.join(lines)


def parse_toy_entries(toybox_dir: Path) -> list[ToyEntry]:
    """Scan ``toys/*/*.c`` for ``USE_*(NEWTOY(...))`` and ``USE_*(OLDTOY(...))`` lines.

    Args:
        toybox_dir: Path to the upstream ``toybox`` source directory.

    Returns:
        List of parsed ``ToyEntry`` instances.
    """
    entries: list[ToyEntry] = [
        ToyEntry(
            guard_sym="TOYBOX",
            kind="NEW",
            name="toybox",
            raw_middle="0",
            flags_expr="TOYFLAG_STAYROOT|TOYFLAG_NOHELP",
            raw_line="USE_TOYBOX(NEWTOY(toybox, 0, TOYFLAG_STAYROOT|TOYFLAG_NOHELP))",
            source_rel="main.c",
        )
    ]

    for c_file in get_toy_source_files(toybox_dir):
        rel = c_file.relative_to(toybox_dir).as_posix()
        text = c_file.read_text(encoding="utf-8", errors="replace")
        for line in text.splitlines():
            match = TOY_LINE_RE.match(line)
            if match is not None:
                entries.append(
                    ToyEntry(
                        guard_sym=match.group(1),
                        kind=match.group(2),
                        name=match.group(3).strip(),
                        raw_middle=match.group(4).strip(),
                        flags_expr=match.group(5).strip(),
                        raw_line=line,
                        source_rel=rel,
                    )
                )
    return entries


def generate_newtoys_h(entries: Sequence[ToyEntry]) -> str:
    """Generate ``generated/newtoys.h`` with ``toybox`` first and remaining entries sorted.

    Sorting uses POSIX C locale byte order on the command name while preserving
    relative order for duplicate names (matching ``sort -s -k 1,1`` in ``make.sh``).

    Args:
        entries: Sequence of parsed ``ToyEntry`` objects.

    Returns:
        Complete text for ``generated/newtoys.h``.
    """
    nl = chr(10)
    if not entries:
        return "USE_TOYBOX(NEWTOY(toybox, 0, TOYFLAG_STAYROOT|TOYFLAG_NOHELP))" + nl

    first = entries[0]
    rest = sorted(entries[1:], key=lambda e: e.name)
    lines = [first.raw_line] + [e.raw_line for e in rest]
    return nl.join(lines) + nl


def select_enabled_toy_sources(
    entries: Sequence[ToyEntry],
    config_map: Mapping[str, int | bool],
) -> list[str]:
    """Return sorted relative paths of ``toys/*/*.c`` files that have an enabled applet.

    Args:
        entries: Sequence of parsed ``ToyEntry`` objects.
        config_map: Mapping of configuration symbol names to boolean or integer values.

    Returns:
        Sorted list of unique relative file paths (e.g. ``["toys/posix/cat.c", ...]``).
    """
    selected: set[str] = set()
    for entry in entries:
        if entry.source_rel == "main.c":
            continue
        if bool(config_map.get(entry.guard_sym, False)):
            selected.add(entry.source_rel)
    return sorted(selected)


def chrtype(ch: str) -> int:
    """Classify an option character according to Toybox ``scripts/mkflags.c``.

    Args:
        ch: Single-character string from a NEWTOY option string.

    Returns:
        Integer classification code (``0``, ``1``, ``2``, or ``3``).
    """
    if ch in "^-:#|@*; %.":
        return 1
    if ch in "=<>":
        return 2
    if ch in "?&0":
        return 3
    return 0


def octane(text: str) -> str:
    """Decode C-style octal escape sequences (matching ``octane()`` in ``mkflags.c``).

    Args:
        text: Input option string potentially containing octal escapes.

    Returns:
        Decoded string.
    """
    bs = chr(92)
    out = bytearray()
    idx = 0
    length = len(text)
    while idx < length:
        if text[idx] == bs:
            val = 0
            idx += 1
            while idx < length and text[idx].isdigit():
                val = (val * 8) + (ord(text[idx]) - ord("0"))
                idx += 1
            out.append(val & 0xFF)
        else:
            out.append(ord(text[idx]))
            idx += 1
    return out.decode("latin1")


def mark_gaps(flags: str, allflags: str) -> str:
    r"""Replace disabled ``USE_*``/``SKIP_*`` sections with ``\x01`` gap markers.

    Replicates ``mark_gaps()`` in ``scripts/mkflags.c`` so ``FLAG_*`` bit
    positions stay constant regardless of sub-feature configuration.

    Args:
        flags: Active option string under the current configuration.
        allflags: Full option string under ``allyesconfig``.

    Returns:
        Option string with ``\x01`` gap placeholders inserted for disabled flags.
    """
    flags_s = flags.lstrip()
    all_s = allflags.lstrip()
    out: list[str] = []
    bare = True
    fi = 0
    ai = 0
    all_len = len(all_s)

    while ai < all_len:
        if all_s[ai] == "(":
            end_idx = all_s.find(")", ai)
            span = (end_idx - ai + 1) if end_idx != -1 else (all_len - ai)
            sub = all_s[ai : ai + span]
            if flags_s[fi : fi + span] != sub:
                if bare:
                    out.append(chr(1))
            else:
                out.append(sub)
                fi += span
            ai += span
            continue

        ch = all_s[ai]
        ai += 1
        if bare and chrtype(ch) == 0:
            bare = False
        if fi < len(flags_s) and flags_s[fi] == ch:
            out.append(ch)
            fi += 1
            continue

        ct = chrtype(ch)
        if ct == 0 or (not bare and ct == 3):
            out.append(chr(1))
        elif ct == 2:
            while ai < all_len and all_s[ai].isdigit():
                ai += 1

    return "".join(out)


def digest_optstring(optstring: str) -> list[FlagNode]:
    """Break a Toybox option string into a reversed list of ``FlagNode`` items.

    Replicates ``digest()`` in ``scripts/mkflags.c``.

    Args:
        optstring: Decoded Toybox option string.

    Returns:
        List of ``FlagNode`` objects ordered from right-to-left (least-significant bit first).

    Raises:
        ValueError: If the option string contains syntax errors (e.g. empty ``()``,
            ``<``/``>``/``=`` without a number, or ``~`` not followed by ``(``).
    """
    nodes: list[FlagNode] = []
    idx = 0
    length = len(optstring)
    while idx < length:
        ch = optstring[idx]
        if ch == "[":
            break
        if ch == "(":
            if idx + 1 < length and optstring[idx + 1] == ")":
                raise ValueError(f"empty () longopt in '{optstring}'")
            end_idx = optstring.find(")", idx + 1)
            if end_idx == -1:
                raise ValueError(f"unterminated (longopt in '{optstring}'")
            lopt_name = optstring[idx + 1 : end_idx].replace("-", "_")
            idx = end_idx + 1
            if nodes and nodes[0].command is not None:
                nodes[0].lopt.insert(0, lopt_name)
            else:
                nodes.insert(0, FlagNode(command=None, lopt=[lopt_name]))
            continue

        ct = chrtype(ch)
        if ct == 1 or (ct == 3 and not nodes):
            idx += 1
        elif ct == 2:
            if idx + 1 < length and optstring[idx + 1] == "-":
                idx += 1
            if idx + 1 >= length or not optstring[idx + 1].isdigit():
                raise ValueError(f"{ch} without number in '{optstring}'")
            idx += 1
            while idx < length and optstring[idx].isdigit():
                if not nodes:
                    idx += 1
                    break
                idx += 1
        else:
            if ch == "~" and (idx + 1 >= length or optstring[idx + 1] != "("):
                raise ValueError(f"~ without (longopt) in '{optstring}'")
            nodes.insert(0, FlagNode(command=ch, lopt=[]))
            idx += 1

    return nodes


def evaluate_optstring(
    raw_middle: str,
    config_map: Mapping[str, int | bool],
    *,
    allyes: bool,
) -> str:
    """Evaluate ``USE_*("...")`` and ``SKIP_*("...")`` macros inside a NEWTOY option string.

    Args:
        raw_middle: Raw second argument of ``NEWTOY(name, raw_middle, flags)``.
        config_map: Mapping of configuration symbol names to boolean or integer values.
        allyes: If ``True``, include all ``USE_*`` and ``SKIP_*`` substrings (as in
            ``make.sh`` pass ``B``); otherwise evaluate against ``config_map``.

    Returns:
        Concatenated string content, or ``" "`` if ``raw_middle`` is ``"0"`` or empty.
    """
    stripped = raw_middle.strip()
    if stripped == "0":
        return " "

    def _replace_macro(match: re.Match[str]) -> str:
        """Substitute a single ``USE_*`` or ``SKIP_*`` macro match.

        Args:
            match: Regex match containing macro kind, symbol name, and string body.

        Returns:
            Quoted string literal to keep or empty ``""`` literal.
        """
        kind = match.group(1)
        sym = match.group(2)
        inner = match.group(3)
        if allyes:
            return f'"{inner}"'
        enabled = bool(config_map.get(sym, False))
        if (kind == "USE" and enabled) or (kind == "SKIP" and not enabled):
            return f'"{inner}"'
        return '""'

    expanded = MACRO_IN_OPT_RE.sub(_replace_macro, stripped)
    parts = QUOTED_STR_RE.findall(expanded)
    joined = "".join(parts)
    return joined if joined else " "


def _format_flag_symbol(node: FlagNode) -> str:
    """Format the ``FLAG_<sym>`` identifier suffix for a ``FlagNode``.

    Args:
        node: Parsed ``FlagNode``.

    Returns:
        Flag suffix string (e.g. ``"v"``, ``"color"``, or ``"X7F"``).
    """
    if node.command is None or node.command == "~":
        return node.lopt[0]
    code = ord(node.command[0])
    if code > 127:
        return f"X{code & 127:02X}"
    return node.command[0]


def generate_flags_h(
    entries: Sequence[ToyEntry],
    config_map: Mapping[str, int | bool],
) -> str:
    """Generate the contents of ``generated/flags.h``.

    Replicates the two-pass preprocessor + ``scripts/mkflags.c`` pipeline in
    ``scripts/make.sh``.

    Args:
        entries: Sequence of parsed ``ToyEntry`` objects.
        config_map: Mapping of configuration symbol names to boolean or integer values.

    Returns:
        Complete C header text for ``generated/flags.h``.
    """
    nl = chr(10)
    header_lines: list[str] = [
        "#undef FORCED_FLAG",
        "#ifdef FORCE_FLAGS",
        "#define FORCED_FLAG 1LL",
        "#else",
        "#define FORCED_FLAG 0LL",
        "#endif",
        "",
    ]
    body_lines: list[str] = []

    ordered = [entries[0]] + sorted(entries[1:], key=lambda e: e.name) if entries else []
    for entry in ordered:
        if entry.kind != "NEW":
            continue

        cmd = entry.name
        is_enabled = bool(config_map.get(entry.guard_sym, False))
        flags_raw = (
            evaluate_optstring(entry.raw_middle, config_map, allyes=False) if is_enabled else " "
        )
        allflags_raw = evaluate_optstring(entry.raw_middle, config_map, allyes=True)

        flags = octane(flags_raw)
        allflags = octane(allflags_raw)

        header_lines.append(f"// {cmd} {flags} {allflags}")
        mgaps: str | None = None
        if flags != " ":
            mgaps = mark_gaps(flags, allflags)
        elif allflags != " ":
            mgaps = allflags

        header_lines.append(f"#undef OPTSTR_{cmd}")
        if mgaps is not None:
            escaped_mgaps = mgaps.replace(chr(1), f"{chr(92)}001")
            header_lines.append(f'#define OPTSTR_{cmd} "{escaped_mgaps}"')
        else:
            header_lines.append(f"#define OPTSTR_{cmd} 0")

        flist = digest_optstring(flags.lstrip())
        aflist = digest_optstring(allflags.lstrip())

        header_lines.append(f"#ifdef CLEANUP_{cmd}")
        header_lines.append(f"#undef CLEANUP_{cmd}")
        header_lines.append(f"#undef FOR_{cmd}")
        for node in aflist:
            header_lines.append(f"#undef FLAG_{_format_flag_symbol(node)}")
        header_lines.append("#endif")
        header_lines.append("")

        body_lines.append(f"#ifdef FOR_{cmd}")
        body_lines.append(f"#define CLEANUP_{cmd}")
        body_lines.append("#ifndef TT")
        body_lines.append(f"#define TT this.{cmd}")
        body_lines.append("#endif")

        flist_idx = 0
        bit = 0
        for anode in aflist:
            sym_name = _format_flag_symbol(anode)
            flag_enabled = False
            fnode = flist[flist_idx] if flist_idx < len(flist) else None
            if anode.command is None or anode.command == "~":
                if fnode is not None and fnode.lopt and fnode.lopt[0] == anode.lopt[0]:
                    flag_enabled = True
            else:
                if fnode is not None and fnode.command == anode.command:
                    flag_enabled = True

            shift_base = "1LL" if flag_enabled else "FORCED_FLAG"
            body_lines.append(f"#define FLAG_{sym_name} ({shift_base}<<{bit})")
            bit += 1
            if flag_enabled:
                flist_idx += 1

        body_lines.append("#endif")
        body_lines.append("")

    return nl.join(header_lines + body_lines)


def generate_globals_h(
    toybox_dir: Path,
    toy_sources: Sequence[str],
) -> str:
    """Generate ``generated/globals.h`` from ``GLOBALS(...)`` blocks in ``toys/*/*.c``.

    Args:
        toybox_dir: Path to the upstream ``toybox`` source directory.
        toy_sources: Relative paths of ``toys/*/*.c`` files to scan.

    Returns:
        Complete C header text for ``generated/globals.h``.
    """
    nl = chr(10)
    tab = chr(9)
    struct_blocks: list[str] = []
    union_members: list[str] = []
    seen_structs: set[str] = set()

    for rel_path in toy_sources:
        full_path = toybox_dir / rel_path
        if not full_path.is_file():
            continue
        text = full_path.read_text(encoding="utf-8", errors="replace")
        for_name: str | None = None
        in_globals = False
        body_lines: list[str] = []

        for line in text.splitlines():
            for_match = FOR_DEF_RE.match(line)
            if for_match is not None:
                for_name = for_match.group(1)

            if line.startswith("GLOBALS("):
                in_globals = True
                body_lines = [line[len("GLOBALS(") :]]
                continue

            if in_globals:
                if line.startswith(")"):
                    in_globals = False
                    if for_name is not None and for_name not in seen_structs:
                        seen_structs.add(for_name)
                        if not any(b.strip() for b in body_lines):
                            body_lines = ["  int _dummy;"]
                        block = nl.join([f"struct {for_name}_data {{", *body_lines, "};", ""])
                        struct_blocks.append(block)
                        union_members.append(f"{tab}struct {for_name}_data {for_name};")
                    body_lines = []
                else:
                    body_lines.append(line)

    if not union_members:
        union_members.append(f"{tab}int _dummy;")

    lines: list[str] = [
        *struct_blocks,
        "extern union global_union {",
        *union_members,
        "} this;",
        "",
    ]
    return nl.join(lines)


def generate_tags_h(toybox_dir: Path) -> str:
    """Generate ``generated/tags.h`` from ``TAGGED_ARRAY(...)`` blocks in ``toys/*/*.c``.

    Args:
        toybox_dir: Path to the upstream ``toybox`` source directory.

    Returns:
        Complete C header text for ``generated/tags.h``.
    """
    nl = chr(10)
    lines: list[str] = []

    for c_file in get_toy_source_files(toybox_dir):
        text = c_file.read_text(encoding="utf-8", errors="replace")
        in_tagged = False
        head = ""
        idx = 0

        for line in text.splitlines():
            match = TAGGED_ARRAY_START_RE.search(line)
            if match is not None:
                in_tagged = True
                head = NON_IDENT_RE.sub("_", match.group(1).strip())
                idx = 0
                continue

            if in_tagged:
                if line.startswith(")"):
                    in_tagged = False
                    continue
                for item_match in TAG_ITEM_RE.finditer(line):
                    raw_tag = item_match.group(1)
                    clean_tag = NON_IDENT_RE.sub("_", raw_tag)
                    name = f"{head}_{clean_tag}"
                    ll_suffix = "LL" if idx >= 31 else ""
                    pad1 = max(1, 32 - len(name))
                    pad2 = max(1, 31 - len(name))
                    lines.append(f"#define {name}{' ' * pad1}{idx}")
                    lines.append(f"#define _{name}{' ' * pad2}(1{ll_suffix}<<{idx})")
                    idx += 1

    lines.append("")
    return nl.join(lines)


def _extract_kconfig_help_entries(text: str) -> list[tuple[str, str]]:
    """Extract ``(symbol, help_text)`` pairs from Kconfig-formatted text.

    Args:
        text: Contents of ``Config.in`` or a ``toys/*/*.c`` file.

    Returns:
        List of ``(symbol, help_text)`` tuples.
    """
    nl = chr(10)
    tab = chr(9)
    results: list[tuple[str, str]] = []
    current_sym: str | None = None
    in_help = False
    help_indent = 0
    help_lines: list[str] = []

    keywords = {"mainmenu", "menu", "choice", "comment", "config", "endmenu", "endchoice"}

    for raw_line in text.splitlines():
        line = raw_line.rstrip()
        if in_help:
            if line == "*/":
                in_help = False
                if help_lines:
                    joined = nl.join(help_lines).rstrip()
                    results.append((str(current_sym), joined))
                help_lines = []
                current_sym = None
                continue

            indent = 0
            idx = 0
            while idx < len(line) and line[idx] in (" ", tab):
                if line[idx] == tab:
                    indent |= 7
                indent += 1
                if help_lines and help_indent < indent:
                    break
                idx += 1

            stripped = line[idx:]
            if not help_lines:
                if not stripped:
                    continue
                help_indent = indent

            if indent < help_indent and stripped:
                in_help = False
                joined = nl.join(help_lines).rstrip()
                results.append((str(current_sym), joined))
                help_lines = []
            else:
                help_lines.append(stripped)
                continue

        lstripped = line.lstrip()
        if not lstripped or lstripped.startswith("#"):
            continue
        parts = lstripped.split(None, 1)
        kw = parts[0]
        arg = parts[1].strip() if len(parts) > 1 else ""

        if kw == "config" and arg:
            current_sym = arg.split()[0]
        elif kw == "help" and not arg and current_sym is not None:
            in_help = True
            help_indent = 0
            help_lines = []
        elif kw in keywords:
            current_sym = None

    if in_help and current_sym is not None and help_lines:
        joined = nl.join(help_lines).rstrip()
        results.append((current_sym, joined))

    return results


def _escape_c_string(text: str) -> str:
    """Escape backslashes, double quotes, and newlines for a C string literal.

    Args:
        text: Raw help text.

    Returns:
        Escaped C string content.
    """
    bs = chr(92)
    dq = chr(34)
    nl = chr(10)
    return text.replace(bs, bs + bs).replace(dq, bs + dq).replace(nl, bs + "n")


def generate_help_h(toybox_dir: Path) -> str:
    """Generate ``generated/help.h`` containing ``#define HELP_<cmd> "..."`` macros.

    Args:
        toybox_dir: Path to the upstream ``toybox`` source directory.

    Returns:
        Complete C header text for ``generated/help.h``.
    """
    nl = chr(10)
    entries: list[tuple[str, str]] = []
    seen: set[str] = set()

    config_in = toybox_dir / "Config.in"
    if config_in.is_file():
        for sym, htext in _extract_kconfig_help_entries(
            config_in.read_text(encoding="utf-8", errors="replace")
        ):
            low = sym.lower()
            if low not in seen:
                seen.add(low)
                entries.append((low, htext))

    for c_file in get_toy_source_files(toybox_dir):
        for sym, htext in _extract_kconfig_help_entries(
            c_file.read_text(encoding="utf-8", errors="replace")
        ):
            low = sym.lower()
            if low not in seen:
                seen.add(low)
                entries.append((low, htext))

    lines: list[str] = []
    for low_sym, htext in entries:
        lines.append(f'#define HELP_{low_sym} "{_escape_c_string(htext)}"')
        lines.append("")

    return nl.join(lines)


def generate_all_toybox_headers(
    toybox_dir: Path,
    out_dir: Path,
    *,
    target_dos: bool = False,
) -> list[str]:
    """Generate all Toybox build-time headers and source lists into ``out_dir``.

    Writes:
      - ``<out_dir>/generated/config.h``
      - ``<out_dir>/generated/newtoys.h``
      - ``<out_dir>/generated/flags.h``
      - ``<out_dir>/generated/globals.h``
      - ``<out_dir>/generated/tags.h``
      - ``<out_dir>/generated/help.h``
      - ``<out_dir>/enabled_sources.cmake``

    Args:
        toybox_dir: Path to the upstream ``toybox`` source directory.
        out_dir: Output directory where ``generated/`` and ``enabled_sources.cmake``
            will be created.
        target_dos: If ``True``, generate for 32-bit Protected-Mode DOS; otherwise
            generate for native Windows (MSVC) / POSIX host.

    Returns:
        List of all relative C source file paths (``main.c``, ``lib/*.c``, and
        enabled ``toys/*/*.c``) to compile.

    Raises:
        FileNotFoundError: If ``toybox_dir`` does not contain ``toys.h`` and ``main.c``.
    """
    nl = chr(10)
    resolved_toybox = toybox_dir.resolve()
    if not (resolved_toybox / "toys.h").is_file() or not (resolved_toybox / "main.c").is_file():
        raise FileNotFoundError(
            f"Invalid toybox source directory (missing toys.h or main.c): {resolved_toybox}"
        )

    gen_dir = out_dir / "generated"
    gen_dir.mkdir(parents=True, exist_ok=True)

    all_symbols = collect_all_config_symbols(resolved_toybox)
    config_map = build_default_config_map(all_symbols, target_dos=target_dos)
    toy_entries = parse_toy_entries(resolved_toybox)

    config_h = generate_config_h(config_map)
    newtoys_h = generate_newtoys_h(toy_entries)
    flags_h = generate_flags_h(toy_entries, config_map)

    all_toy_files = [
        p.relative_to(resolved_toybox).as_posix() for p in get_toy_source_files(resolved_toybox)
    ]
    globals_h = generate_globals_h(resolved_toybox, all_toy_files)
    tags_h = generate_tags_h(resolved_toybox)
    help_h = generate_help_h(resolved_toybox)

    (gen_dir / "config.h").write_text(config_h, encoding="utf-8")
    (gen_dir / "newtoys.h").write_text(newtoys_h, encoding="utf-8")
    (gen_dir / "flags.h").write_text(flags_h, encoding="utf-8")
    (gen_dir / "globals.h").write_text(globals_h, encoding="utf-8")
    (gen_dir / "tags.h").write_text(tags_h, encoding="utf-8")
    (gen_dir / "help.h").write_text(help_h, encoding="utf-8")

    sys_dir = out_dir / "sys"
    sys_dir.mkdir(parents=True, exist_ok=True)
    win_dos_cond = (
        "defined(_WIN32) || defined(_MSC_VER) || defined(__WATCOMC__) "
        "|| defined(__DOS__) || defined(__MSDOS__)"
    )
    not_win_dos_cond = (
        "!defined(_WIN32) && !defined(_MSC_VER) && !defined(__WATCOMC__) "
        "&& !defined(__DOS__) && !defined(__MSDOS__)"
    )
    bsd_apple_cond = (
        "defined(__APPLE__) || defined(__FreeBSD__) || defined(__OpenBSD__) || defined(__NetBSD__)"
    )
    (sys_dir / "mount.h").write_text(
        f"#ifndef TOYBOX_GEN_SYS_MOUNT_H{nl}"
        f"#define TOYBOX_GEN_SYS_MOUNT_H{nl}"
        f"#if {win_dos_cond}{nl}"
        f"#include <sys/statfs.h>{nl}"
        f"#include <sys/statvfs.h>{nl}"
        f"#elif {bsd_apple_cond}{nl}"
        f"#include_next <sys/mount.h>{nl}"
        f"#endif{nl}"
        f"#endif{nl}",
        encoding="utf-8",
    )
    (sys_dir / "syscall.h").write_text(
        f"#ifndef TOYBOX_GEN_SYS_SYSCALL_H{nl}"
        f"#define TOYBOX_GEN_SYS_SYSCALL_H{nl}"
        f"#if {not_win_dos_cond}{nl}"
        f"#include_next <sys/syscall.h>{nl}"
        f"#endif{nl}"
        f"#endif{nl}",
        encoding="utf-8",
    )
    (sys_dir / "ttydefaults.h").write_text(
        f"#ifndef TOYBOX_GEN_SYS_TTYDEFAULTS_H{nl}"
        f"#define TOYBOX_GEN_SYS_TTYDEFAULTS_H{nl}"
        f"#ifndef CTRL{nl}"
        f"#define CTRL(x) ((x)&037){nl}"
        f"#endif{nl}"
        f"#endif{nl}",
        encoding="utf-8",
    )
    stub_headers = (
        "sys/swap.h",
        "sys/xattr.h",
        "sys/inotify.h",
        "pty.h",
        "utmpx.h",
        "shadow.h",
    )
    for stub_name in stub_headers:
        guard = "TOYBOX_GEN_" + NON_IDENT_RE.sub("_", stub_name).upper()
        (out_dir / stub_name).write_text(
            f"#ifndef {guard}{nl}"
            f"#define {guard}{nl}"
            f"#if {not_win_dos_cond}{nl}"
            f"#if defined(__has_include_next){nl}"
            f"#if __has_include_next(<{stub_name}>){nl}"
            f"#include_next <{stub_name}>{nl}"
            f"#endif{nl}"
            f"#endif{nl}"
            f"#endif{nl}"
            f"#endif{nl}",
            encoding="utf-8",
        )
    (out_dir / "sched.h").write_text(
        f"#ifndef TOYBOX_GEN_SCHED_H{nl}"
        f"#define TOYBOX_GEN_SCHED_H{nl}"
        f"#if {win_dos_cond}{nl}"
        f'#include "posix-sched.h"{nl}'
        f"#else{nl}"
        f"#include_next <sched.h>{nl}"
        f"#endif{nl}"
        f"#endif{nl}",
        encoding="utf-8",
    )

    enabled_toys = select_enabled_toy_sources(toy_entries, config_map)
    all_sources: list[str] = ["main.c"]
    for lib_rel in CORE_LIB_SOURCES:
        if (resolved_toybox / lib_rel).is_file():
            all_sources.append(lib_rel)
    all_sources.extend(enabled_toys)

    cmake_lines = ["set(TOYBOX_ENABLED_REL_SOURCES"]
    for src in all_sources:
        cmake_lines.append(f'    "{src}"')
    cmake_lines.append(")")
    cmake_lines.append("")
    (out_dir / "enabled_sources.cmake").write_text(nl.join(cmake_lines), encoding="utf-8")

    return all_sources


def parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    """Parse CLI arguments for ``generate_toybox_headers.py``.

    Args:
        argv: Optional sequence of CLI arguments (defaults to ``sys.argv[1:]``).

    Returns:
        Parsed ``argparse.Namespace``.
    """
    parser = argparse.ArgumentParser(
        description="Generate Toybox build-time headers (generated/*.h) and source lists."
    )
    parser.add_argument(
        "--toybox-dir",
        type=Path,
        required=True,
        help="Path to the upstream toybox repository.",
    )
    parser.add_argument(
        "--out-dir",
        type=Path,
        required=True,
        help="Output directory for generated headers and enabled_sources.cmake.",
    )
    parser.add_argument(
        "--dos",
        action="store_true",
        help="Generate configuration for 32-bit Protected-Mode DOS (OpenWatcom).",
    )
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    """Run the Toybox header generator CLI entry point.

    Args:
        argv: Optional sequence of CLI arguments.

    Returns:
        Exit status code (``0`` on success, ``1`` on error).
    """
    args = parse_args(argv)
    try:
        generate_all_toybox_headers(
            toybox_dir=args.toybox_dir,
            out_dir=args.out_dir,
            target_dos=bool(args.dos),
        )
    except (FileNotFoundError, ValueError) as exc:
        print(f"Error generating Toybox headers: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
