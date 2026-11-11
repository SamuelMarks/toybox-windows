Toybox Windows (MSVC) & DOS (OpenWatcom) Native Builds
======================================================

[![License](https://img.shields.io/badge/license-CC0%20OR%20Apache--2.0%20OR%20MIT-blue.svg)](https://opensource.org/licenses/Apache-2.0)
[![CI](https://github.com/SamuelMarks/toybox-windows/actions/workflows/ci.yml/badge.svg)](https://github.com/SamuelMarks/toybox-windows/actions/workflows/ci.yml)
![Doc Coverage](https://img.shields.io/badge/doc%20coverage-100%25-brightgreen)
![Test Coverage](https://img.shields.io/badge/test%20coverage-100%25-brightgreen)

This repository provides **native Windows builds** (compiled with Microsoft Visual C++ / MSVC) and **32-bit Protected-Mode DOS builds** (compiled with OpenWatcom v2) of [Toybox](https://landley.net/toybox/) (`0.8.15`) using CMake and [auto-win-msvc](https://github.com/SamuelMarks/auto-win-msvc)—**without modifying a single `.c` or `.h` file in the upstream `toybox` repository**.

---

## Features & Architecture

- **Zero Upstream Source Modifications**: All upstream `.c` and `.h` files in `../toybox` remain 100% untouched.
- **No Checked-in `.c` or `.h` Files**: Enforced via the `forbid-c-headers-and-sources` pre-commit hook. All POSIX/BSD/Linux polyfills and C99/GNU-to-C89/MSVC/Watcom AST source transformations come from `auto-win-msvc`, and all Toybox build-time headers (`generated/config.h`, `generated/newtoys.h`, `generated/flags.h`, `generated/globals.h`, `generated/tags.h`, `generated/help.h`) are deterministically generated into the CMake build directory by `cmake/GenerateToyboxHeaders.cmake`.
- **Native Windows (MSVC `cl.exe` & MinGW-w64)**:
  - Builds 155+ Toybox applets (`awk`, `base64`, `bc`, `bzcat`, `cal`, `cat`, `cksum`, `cmp`, `comm`, `cp`, `cpio`, `crc32`, `cut`, `date`, `dd`, `df`, `diff`, `dirname`, `dos2unix`, `du`, `echo`, `env`, `expr`, `factor`, `file`, `find`, `fmt`, `fold`, `grep`, `gunzip`, `gzip`, `head`, `hexdump`, `hexedit`, `ls`, `md5sum`, `mkdir`, `mv`, `nc`/`netcat`, `nl`, `od`, `paste`, `patch`, `printf`, `pwd`, `readelf`, `realpath`, `rev`, `rm`, `rmdir`, `sed`, `seq`, `sha1sum`, `sha256sum`, `sha512sum`, `sha3sum`, `sort`, `split`, `stat`, `strings`, `tac`, `tail`, `tar`, `tee`, `test`, `touch`, `tr`, `truncate`, `tsort`, `uname`, `uniq`, `unix2dos`, `uudecode`, `uuencode`, `uuidgen`, `vi`, `wc`, `wget`, `which`, `whoami`, `xargs`, `xxd`, `xzcat`, `yes`, `zcat`, etc.) into a single self-contained `toybox.exe` multicall binary.
- **32-bit Protected-Mode DOS (OpenWatcom v2 `wcl386`)**:
  - Compiles `toybox.exe` (`TOYBOX.EXE`) as a 32-bit Linear Executable (`LE`) with `DOS32A.EXE` / `DOS4GW.EXE` DOS extender support and `auto-win-msvc` single-tasking DOS shims.
  - Verified inside **MS-DOS 1.25**, **MS-DOS 2.0**, and **MS-DOS 4.0** QEMU Vagrant boxes (`vagrant/dos/Vagrantfile`).

---

## Building for Windows (MSVC)

```bat
release.bat
```

Or manually with CMake:

```sh
cmake -B build_msvc -S . -DCMAKE_BUILD_TYPE=Release
cmake --build build_msvc --config Release
ctest --test-dir build_msvc -C Release --output-on-failure
```

---

## Building for 32-bit Protected-Mode DOS (OpenWatcom v2)

```bat
release_dos.bat
```

Or on macOS / Linux with OpenWatcom v2:

```sh
export WATCOM=/path/to/watcom
export PATH="$WATCOM/binl64:$WATCOM/binw:$PATH"
export INCLUDE="$WATCOM/h"
export EDPATH="$WATCOM/eddat"
export WIPFC="$WATCOM/wipfc"

cmake -G "Watcom WMake" -B build_dos -S .
  -DCMAKE_SYSTEM_NAME=DOS
  -DCMAKE_SYSTEM_PROCESSOR=I386
  -DCMAKE_C_COMPILER="$WATCOM/binl64/wcl386"
  -DCMAKE_C_FLAGS_INIT="-bt=dos -mf -3r -zq"
  -DCMAKE_BUILD_TYPE=Release
  -DBUILD_SHARED_LIBS=OFF

cmake --build build_dos --config Release
```

---

## License

Dual/triple-licensed under **Apache-2.0**, **MIT**, or **CC0-1.0** for the build scripts and tooling in this repository. Upstream Toybox is licensed under the **Zero Clause BSD License (0BSD)**.
