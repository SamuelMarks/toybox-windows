"""Unit tests for ``scripts.generate_toybox_headers`` and ``cmake/GenerateToyboxHeaders.cmake``."""

from __future__ import annotations

import runpy
import subprocess
import sys
from pathlib import Path

import pytest

from scripts.generate_toybox_headers import (
    FlagNode,
    ToyEntry,
    _extract_kconfig_help_entries,
    _format_flag_symbol,
    build_default_config_map,
    chrtype,
    collect_all_config_symbols,
    digest_optstring,
    evaluate_optstring,
    generate_all_toybox_headers,
    generate_config_h,
    generate_flags_h,
    generate_globals_h,
    generate_help_h,
    generate_newtoys_h,
    generate_tags_h,
    get_toy_source_files,
    main,
    mark_gaps,
    octane,
    parse_args,
    parse_toy_entries,
    select_enabled_toy_sources,
)

CMAKE_SCRIPT = Path(__file__).resolve().parent.parent / "cmake" / "GenerateToyboxHeaders.cmake"


def _create_mock_toybox_tree(root: Path) -> Path:
    """Create a minimal synthetic ``toybox`` source tree in ``root`` for unit testing.

    Args:
        root: Base directory in which to create ``toybox/``.

    Returns:
        Path to the created synthetic ``toybox`` directory.
    """
    nl = chr(10)
    tab = chr(9)
    bs = chr(92)
    tb = root / "toybox"
    lib_dir = tb / "lib"
    posix_dir = tb / "toys" / "posix"
    other_dir = tb / "toys" / "other"
    lib_dir.mkdir(parents=True)
    posix_dir.mkdir(parents=True)
    other_dir.mkdir(parents=True)

    (tb / "toys.h").write_text(f'#define TOYBOX_VERSION "0.8.15"{nl}', encoding="utf-8")
    (tb / "main.c").write_text(f"/* main.c */{nl}", encoding="utf-8")
    (lib_dir / "args.c").write_text(f"/* args.c */{nl}", encoding="utf-8")
    (lib_dir / "lib.h").write_text(f"/* lib.h */{nl}", encoding="utf-8")

    (tb / "Config.in").write_text(
        nl.join(
            [
                "# Comment line",
                'mainmenu "Toybox Configuration"',
                "",
                "config TOYBOX",
                '  bool "Toybox"',
                "  default y",
                "  help",
                "",
                f"{tab}Toybox multicall binary.",
                f"{tab}  Indented detail line.",
                "",
                "config TOYBOX_UID_SYS",
                '  int "First system UID"',
                "  default 100",
                "",
                "endmenu",
                "",
            ]
        ),
        encoding="utf-8",
    )

    (posix_dir / "cat.c").write_text(
        nl.join(
            [
                "/* cat.c",
                (
                    'USE_CAT(NEWTOY(cat, "u"USE_CAT_V("vte")'
                    'SKIP_TOYBOX_LSM_NONE("Z:")"(long-opt)~(bare-long)n#<1=-2[+uv]", '
                    "TOYFLAG_BIN))"
                ),
                "USE_EGREP(OLDTOY(egrep, cat, TOYFLAG_BIN))",
                "",
                "config CAT",
                '  bool "cat"',
                "  default y",
                "  help",
                "    usage: cat [-u] [FILE...]",
                "",
                "    Copy files to stdout.",
                "*/",
                "#define FOR_cat",
                '#include "toys.h"',
                "GLOBALS(",
                "  char *opt;",
                ")",
                "TAGGED_ARRAY(CAT_TAG,",
                '  {"alpha"}, {"beta-1"},',
                ")",
                "void cat_main(void) {}",
                "",
            ]
        ),
        encoding="utf-8",
    )

    (other_dir / "emptyglob.c").write_text(
        nl.join(
            [
                "/* emptyglob.c",
                f'USE_TRUE(NEWTOY(true, "{bs}200", TOYFLAG_BIN))',
                "USE_FALSE(NEWTOY(false, 0, TOYFLAG_BIN))",
                "config TRUE",
                '  bool "true"',
                "  help",
                "    Return zero.",
                "config NOHELP_SYM",
                '  bool "nohelp"',
                "*/",
                "#define FOR_true",
                "GLOBALS(  int inline_field;",
                ")",
                "#define FOR_false",
                "GLOBALS(",
                ")",
                "#define FOR_false",
                "GLOBALS(",
                ")",
                "TAGGED_ARRAY(EMPTY_INVALID)",
                "",
            ]
        ),
        encoding="utf-8",
    )

    return tb


def test_unit_helpers_and_option_parsing(tmp_path: Path) -> None:
    """Verify helper functions, ``octane``, ``mark_gaps``, ``digest_optstring``, and error branches.

    Args:
        tmp_path: Pytest temporary directory fixture.
    """
    nl = chr(10)
    bs = chr(92)

    # get_toy_source_files when toys/ does not exist
    assert get_toy_source_files(tmp_path / "missing_dir") == []

    # chrtype classifications
    assert chrtype(":") == 1
    assert chrtype("<") == 2
    assert chrtype("&") == 3
    assert chrtype("a") == 0

    # octane octal decoding
    assert octane(f"a{bs}001b{bs}177") == "a" + chr(1) + "b" + chr(127)

    # mark_gaps with longopts, bare flags, and numeric constraints
    gaps1 = mark_gaps("ab", "(long)a<12b")
    assert chr(1) in gaps1
    gaps2 = mark_gaps("(long)ab", "(long)a?b")
    assert "(long)" in gaps2
    gaps3 = mark_gaps("a", "(unclosed")
    assert chr(1) in gaps3
    gaps4 = mark_gaps("a", "a(late)")
    assert chr(1) not in gaps4

    # digest_optstring error branches
    with pytest.raises(ValueError, match=r"empty \(\) longopt"):
        digest_optstring("a()")
    with pytest.raises(ValueError, match=r"unterminated \(longopt"):
        digest_optstring("a(unclosed")
    with pytest.raises(ValueError, match=r"< without number"):
        digest_optstring("<x")
    with pytest.raises(ValueError, match=r"~ without \(longopt\)"):
        digest_optstring("~x")

    # digest_optstring valid complex string
    nodes = digest_optstring("?a(long-a)#<-12=34~(bare-b)[!ab]")
    syms = [_format_flag_symbol(n) for n in nodes]
    assert "bare_b" in syms
    assert "a" in syms
    assert _format_flag_symbol(FlagNode(command=chr(200), lopt=[])) == f"X{200 & 127:02X}"

    # digest_optstring with bare leading longopt and leading numeric constraint
    bare_nodes = digest_optstring("(leading-long)a")
    assert bare_nodes[0].command == "a"
    lead_num_nodes = digest_optstring("<12a")
    assert lead_num_nodes[0].command == "a"

    # evaluate_optstring when raw_middle produces empty quotes and when USE_ is enabled
    assert evaluate_optstring('USE_DISABLED("x")', {"DISABLED": False}, allyes=False) == " "
    assert evaluate_optstring('USE_ENABLED("x")', {"ENABLED": True}, allyes=False) == "x"

    # generate_flags_h with a disabled NEWTOY that has options (hits elif allflags != " ":)
    disabled_entry = ToyEntry(
        guard_sym="DISABLED_CMD",
        kind="NEW",
        name="disabled_cmd",
        raw_middle='"(bare-opt)a"',
        flags_expr="TOYFLAG_BIN",
        raw_line='USE_DISABLED_CMD(NEWTOY(disabled_cmd, "(bare-opt)a", TOYFLAG_BIN))',
        source_rel="toys/other/disabled.c",
    )
    assert select_enabled_toy_sources([disabled_entry], {"DISABLED_CMD": False}) == []
    disabled_flags_h = generate_flags_h([disabled_entry], {"DISABLED_CMD": False})
    assert '#define OPTSTR_disabled_cmd "(bare-opt)a"' in disabled_flags_h

    # generate_newtoys_h on empty sequence
    assert "USE_TOYBOX(NEWTOY(" in generate_newtoys_h([])

    # generate_globals_h when no sources exist -> _dummy union member
    empty_glob = generate_globals_h(tmp_path, ["nonexistent.c"])
    assert "int _dummy;" in empty_glob

    # _extract_kconfig_help_entries edge cases (closing */, dedent exit, duplicate symbols)
    eof_help = _extract_kconfig_help_entries(
        f"config FOO{nl}  help{nl}    line1{nl}"
        f"config BAR{nl}  help{nl}*/{nl}"
        f"config BAZ{nl}  help{nl}    eof help line"
    )
    assert ("FOO", "line1") in eof_help
    assert ("BAZ", "eof help line") in eof_help

    # generate_help_h with duplicate symbol across Config.in and toys/*/*.c
    dup_tb = tmp_path / "dup_tb"
    dup_posix = dup_tb / "toys" / "posix"
    dup_posix.mkdir(parents=True)
    (dup_tb / "Config.in").write_text(
        f"config DUP{nl}  help{nl}    first{nl}config DUP{nl}  help{nl}    second{nl}",
        encoding="utf-8",
    )
    (dup_posix / "dup.c").write_text(
        f"config DUP{nl}  help{nl}    third{nl}",
        encoding="utf-8",
    )
    dup_help = generate_help_h(dup_tb)
    assert dup_help.count("#define HELP_dup ") == 1

    # generate_tags_h with >= 31 tags (1LL<<idx branch)
    many_tags_tb = tmp_path / "many_tags_tb"
    many_tags_dir = many_tags_tb / "toys" / "posix"
    many_tags_dir.mkdir(parents=True)
    items = ", ".join(f'{{"t{i}"}}' for i in range(35))
    (many_tags_dir / "ps.c").write_text(f"TAGGED_ARRAY(PS,{nl}  {items}{nl}){nl}", encoding="utf-8")
    tags_out = generate_tags_h(many_tags_tb)
    assert "(1LL<<31)" in tags_out


def test_generate_all_toybox_headers_and_cli(
    tmp_path: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """Verify full header generation for Windows and DOS profiles plus CLI entry points.

    Args:
        tmp_path: Pytest temporary directory fixture.
        capsys: Pytest stdout/stderr capture fixture.
    """
    tb_dir = _create_mock_toybox_tree(tmp_path)
    out_win = tmp_path / "out_win"
    out_dos = tmp_path / "out_dos"

    all_syms = collect_all_config_symbols(tb_dir)
    assert "CAT" in all_syms
    assert "TOYBOX_UID_SYS" in all_syms

    win_map = build_default_config_map(all_syms, target_dos=False)
    dos_map = build_default_config_map(all_syms, target_dos=True)
    assert win_map["DF"] is True
    assert dos_map["DF"] is False
    assert win_map["TOYBOX_UID_SYS"] == 100

    cfg_h = generate_config_h(win_map)
    assert "#define CFG_CAT 1" in cfg_h
    assert "#define CFG_TOYBOX_UID_SYS 100" in cfg_h

    entries = parse_toy_entries(tb_dir)
    assert any(e.name == "cat" for e in entries)
    enabled_srcs = select_enabled_toy_sources(entries, win_map)
    assert "toys/posix/cat.c" in enabled_srcs

    flags_h = generate_flags_h(entries, win_map)
    assert "#ifdef FOR_cat" in flags_h
    assert "#define OPTSTR_false 0" in flags_h

    help_h = generate_help_h(tb_dir)
    assert '#define HELP_cat "' in help_h
    assert '#define HELP_toybox "' in help_h

    # Full generation via CLI main() for Windows and DOS
    assert main(["--toybox-dir", str(tb_dir), "--out-dir", str(out_win)]) == 0
    assert main(["--toybox-dir", str(tb_dir), "--out-dir", str(out_dos), "--dos"]) == 0

    for gen_file in ("config.h", "newtoys.h", "flags.h", "globals.h", "tags.h", "help.h"):
        assert (out_win / "generated" / gen_file).is_file()
        assert (out_dos / "generated" / gen_file).is_file()
    assert (out_win / "enabled_sources.cmake").is_file()
    assert (out_win / "sys" / "mount.h").is_file()

    # Error path when toybox-dir is missing toys.h
    bad_dir = tmp_path / "bad_tb"
    bad_dir.mkdir()
    assert main(["--toybox-dir", str(bad_dir), "--out-dir", str(out_win)]) == 1
    assert "Error generating Toybox headers" in capsys.readouterr().err

    # Also test when Config.in and lib/ are absent from toybox_dir
    nl = chr(10)
    minimal_tb = tmp_path / "minimal_tb"
    minimal_tb.mkdir()
    (minimal_tb / "toys.h").write_text(f"/* toys.h */{nl}", encoding="utf-8")
    (minimal_tb / "main.c").write_text(f"/* main.c */{nl}", encoding="utf-8")
    out_min = tmp_path / "out_min"
    srcs_min = generate_all_toybox_headers(minimal_tb, out_min, target_dos=False)
    assert srcs_min == ["main.c"]

    # __main__ execution
    parsed = parse_args(["--toybox-dir", "tb", "--out-dir", "out", "--dos"])
    assert parsed.dos is True

    old_argv = sys.argv
    sys.argv = [
        "generate_toybox_headers.py",
        "--toybox-dir",
        str(bad_dir),
        "--out-dir",
        str(out_win),
    ]
    try:
        script_path = (
            Path(__file__).resolve().parent.parent / "scripts" / "generate_toybox_headers.py"
        )
        with pytest.raises(SystemExit) as exc_info:
            runpy.run_path(str(script_path), run_name="__main__")
        assert exc_info.value.code == 1
    finally:
        sys.argv = old_argv
    capsys.readouterr()


def test_cmake_script_mode_integration(tmp_path: Path) -> None:
    """Verify ``cmake/GenerateToyboxHeaders.cmake`` in CMake script mode.

    Args:
        tmp_path: Pytest temporary directory fixture.
    """
    tb_dir = _create_mock_toybox_tree(tmp_path)
    out_win = tmp_path / "cmake_out_win"
    out_dos = tmp_path / "cmake_out_dos"

    res_win = subprocess.run(
        [
            "cmake",
            f"-DTOYBOX_DIR={tb_dir}",
            f"-DOUT_DIR={out_win}",
            "-P",
            str(CMAKE_SCRIPT),
        ],
        capture_output=True,
        text=True,
        check=False,
    )
    assert res_win.returncode == 0, res_win.stderr
    assert (out_win / "generated" / "config.h").is_file()

    res_dos = subprocess.run(
        [
            "cmake",
            f"-DTOYBOX_DIR={tb_dir}",
            f"-DOUT_DIR={out_dos}",
            "-DTARGET_DOS=ON",
            "-DFETCH_TOYBOX=ON",
            "-P",
            str(CMAKE_SCRIPT),
        ],
        capture_output=True,
        text=True,
        check=False,
    )
    assert res_dos.returncode == 0, res_dos.stderr
    assert (out_dos / "generated" / "config.h").is_file()

    # Error path when TOYBOX_DIR is missing
    res_err = subprocess.run(
        ["cmake", "-P", str(CMAKE_SCRIPT)],
        capture_output=True,
        text=True,
        check=False,
    )
    assert res_err.returncode != 0
    assert "TOYBOX_DIR is required" in res_err.stderr
