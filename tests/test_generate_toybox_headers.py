"""Unit tests for ``cmake/GenerateToyboxHeaders.cmake``."""

from __future__ import annotations

import subprocess
from pathlib import Path

CMAKE_SCRIPT = Path(__file__).resolve().parent.parent / "cmake" / "GenerateToyboxHeaders.cmake"


def _create_mock_toybox_tree(root: Path) -> Path:
    """Create a synthetic ``toybox`` source tree in ``root`` for CMake unit testing.

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
                "  long count;",
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
    for gen_file in ("config.h", "newtoys.h", "flags.h", "globals.h", "tags.h", "help.h"):
        assert (out_win / "generated" / gen_file).is_file()
    assert (out_win / "enabled_sources.cmake").is_file()
    assert (out_win / "sys" / "mount.h").is_file()

    cfg_h = (out_win / "generated" / "config.h").read_text(encoding="utf-8")
    assert "#define CFG_CAT 1" in cfg_h
    assert "#define CFG_DF 1" in cfg_h
    assert "#define CFG_TOYBOX_UID_SYS 100" in cfg_h

    flags_h = (out_win / "generated" / "flags.h").read_text(encoding="utf-8")
    assert "#ifdef FOR_cat" in flags_h
    assert "#define OPTSTR_false 0" in flags_h
    assert "#define FLAG_X00 (1LL<<0)" in flags_h

    globals_h = (out_win / "generated" / "globals.h").read_text(encoding="utf-8")
    assert "intptr_t count;" in globals_h
    assert "int _dummy;" in globals_h

    tags_h = (out_win / "generated" / "tags.h").read_text(encoding="utf-8")
    assert "#define CAT_TAG_alpha" in tags_h
    assert "#define _CAT_TAG_beta_1" in tags_h

    help_h = (out_win / "generated" / "help.h").read_text(encoding="utf-8")
    assert '#define HELP_cat "' in help_h
    assert '#define HELP_toybox "' in help_h

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
    dos_cfg_h = (out_dos / "generated" / "config.h").read_text(encoding="utf-8")
    assert "#define CFG_DF 0" in dos_cfg_h

    # Error path when TOYBOX_DIR is missing
    res_err = subprocess.run(
        ["cmake", "-P", str(CMAKE_SCRIPT)],
        capture_output=True,
        text=True,
        check=False,
    )
    assert res_err.returncode != 0
    assert "TOYBOX_DIR is required" in res_err.stderr

    # Error path when TOYBOX_DIR is invalid (missing toys.h)
    bad_dir = tmp_path / "bad_tb"
    bad_dir.mkdir()
    res_bad = subprocess.run(
        [
            "cmake",
            f"-DTOYBOX_DIR={bad_dir}",
            f"-DOUT_DIR={out_win}",
            "-P",
            str(CMAKE_SCRIPT),
        ],
        capture_output=True,
        text=True,
        check=False,
    )
    assert res_bad.returncode != 0
    assert "Invalid toybox source directory" in res_bad.stderr
