# =============================================================================
# cmake/GenerateToyboxHeaders.cmake - Pure CMake Build-Time Header & Source Codegen
#
# Replaces Toybox's POSIX shell and host-compiler scripts (scripts/genconfig.sh,
# scripts/make.sh, scripts/mkflags.c, and scripts/kconfig.c) with a 100% pure
# CMake implementation that deterministically generates:
#   1. generated/config.h
#   2. generated/newtoys.h
#   3. generated/flags.h
#   4. generated/globals.h
#   5. generated/tags.h
#   6. generated/help.h
#   7. sys/*.h, pty.h, utmpx.h, shadow.h, sched.h portable stub headers
#   8. enabled_sources.cmake
#
# Also provides toybox_ensure_source() for shallow HTTPS fetching of upstream
# Toybox with multi-mirror fallback, and toybox_parse_version().
# =============================================================================

set(TOYBOX_DEFAULT_REV "0.8.15")
set(TOYBOX_DEFAULT_REPOS
    "https://github.com/landley/toybox.git"
    "https://codeberg.org/landley/toybox.git"
)

string(ASCII 1 _TB_SOH)
string(ASCII 2 _TB_STX)
string(ASCII 3 _TB_ETX)
string(ASCII 4 _TB_EOT)
string(ASCII 5 _TB_ENQ)
string(ASCII 6 _TB_ACK)
string(ASCII 9 _TB_TAB)
string(ASCII 10 _TB_NL)
string(ASCII 13 _TB_CR)
string(ASCII 34 _TB_DQ)
string(ASCII 35 _TB_HASH)
string(ASCII 59 _TB_SEMI)
string(ASCII 91 _TB_LBRACK)
string(ASCII 92 _TB_BS)
string(ASCII 93 _TB_RBRACK)

# Core library sources portable across Windows (MSVC), DOS (OpenWatcom), and POSIX
set(TOYBOX_CORE_LIB_SOURCES
    "lib/args.c"
    "lib/commas.c"
    "lib/deflate.c"
    "lib/dirtree.c"
    "lib/elf.c"
    "lib/env.c"
    "lib/hash.c"
    "lib/lib.c"
    "lib/llist.c"
    "lib/net.c"
    "lib/password.c"
    "lib/portability.c"
    "lib/tty.c"
    "lib/utf8.c"
    "lib/xwrap.c"
)

# Portable applets enabled for both Windows (MSVC) and 32-bit DOS (OpenWatcom)
set(TOYBOX_COMMON_ENABLED_SYMBOLS
    # Global Toybox settings
    "TOYBOX"
    "TOYBOX_LSM_NONE"
    "TOYBOX_FLOAT"
    "TOYBOX_HELP"
    "TOYBOX_HELP_DASHDASH"
    "TOYBOX_NORECURSE"
    # toys/posix
    "BASENAME"
    "CAL"
    "CAT"
    "CHGRP"
    "CHOWN"
    "CHMOD"
    "CKSUM"
    "CRC32"
    "CMP"
    "COMM"
    "CP"
    "MV"
    "INSTALL"
    "CPIO"
    "CUT"
    "DATE"
    "DD"
    "DIRNAME"
    "DU"
    "ECHO"
    "ENV"
    "EXPAND"
    "FALSE"
    "FILE"
    "FIND"
    "FOLD"
    "GREP"
    "EGREP"
    "FGREP"
    "HEAD"
    "ID"
    "GROUPS"
    "LOGNAME"
    "WHOAMI"
    "LINK"
    "LN"
    "LS"
    "MKDIR"
    "MKFIFO"
    "NICE"
    "NL"
    "OD"
    "PASTE"
    "PATCH"
    "PRINTF"
    "PWD"
    "RM"
    "RMDIR"
    "SED"
    "SLEEP"
    "SORT"
    "SPLIT"
    "STRINGS"
    "TAIL"
    "TAR"
    "TEE"
    "TEST"
    "TEST_GLUE"
    "TIME"
    "TOUCH"
    "TRUE"
    "TSORT"
    "TTY"
    "UNAME"
    "ARCH"
    "UNIQ"
    "UNLINK"
    "UUDECODE"
    "UUENCODE"
    "WC"
    "XARGS"
    # toys/lsb
    "GZIP"
    "GUNZIP"
    "ZCAT"
    "HOSTNAME"
    "DNSDOMAINNAME"
    "MD5SUM"
    "SHA1SUM"
    "SHA224SUM"
    "SHA256SUM"
    "SHA384SUM"
    "SHA512SUM"
    "MKTEMP"
    "SEQ"
    "SYNC"
    # toys/other
    "ASCII"
    "UNICODE"
    "BASE64"
    "BASE32"
    "BZCAT"
    "BUNZIP2"
    "CLEAR"
    "COUNT"
    "DOS2UNIX"
    "UNIX2DOS"
    "FACTOR"
    "FMT"
    "FSYNC"
    "GETOPT"
    "HD"
    "HELP"
    "HEXEDIT"
    "MCOOKIE"
    "MKPASSWD"
    "MOUNTPOINT"
    "PRINTENV"
    "PWGEN"
    "READELF"
    "READLINK"
    "REALPATH"
    "RESET"
    "REV"
    "SHA3SUM"
    "SHRED"
    "SHUF"
    "STAT"
    "TAC"
    "TRUNCATE"
    "TS"
    "USLEEP"
    "UUIDGEN"
    "WHICH"
    "XXD"
    "YES"
    # toys/pending
    "AWK"
    "BC"
    "CSPLIT"
    "DIFF"
    "EXPR"
    "HEXDUMP"
    "MORE"
    "TR"
    "XZCAT"
)

# Additional applets enabled on Windows (MSVC) and POSIX hosts
set(TOYBOX_WINDOWS_EXTRA_SYMBOLS
    "DF"
    "KILL"
    "KILLALL"
    "KILLALL5"
    "LOGGER"
    "NOHUP"
    "PIDOF"
    "RENICE"
    "SETSID"
    "TIMEOUT"
    "WATCH"
    "FTPGET"
    "FTPPUT"
    "HTTPD"
    "NETCAT"
    "NC"
    "WGET"
    "VI"
)

set(TOYBOX_INT_SYMBOLS
    "TOYBOX_UID_SYS"
    "TOYBOX_UID_USR"
)
set(TOYBOX_INT_VAL_TOYBOX_UID_SYS 100)
set(TOYBOX_INT_VAL_TOYBOX_UID_USR 500)

# -----------------------------------------------------------------------------
# Internal Helper: Read file and split into lines preserving empty lines
# -----------------------------------------------------------------------------
function(_tb_read_lines FILE_PATH OUT_LINES_VAR)
    file(READ "${FILE_PATH}" _raw)
    string(REPLACE "${_TB_CR}${_TB_NL}" "${_TB_NL}" _raw "${_raw}")
    string(REPLACE "${_TB_BS}" "${_TB_SOH}" _raw "${_raw}")
    string(REPLACE ";" "${_TB_STX}" _raw "${_raw}")
    string(REPLACE "${_TB_LBRACK}" "${_TB_EOT}" _raw "${_raw}")
    string(REPLACE "${_TB_RBRACK}" "${_TB_ENQ}" _raw "${_raw}")
    string(REPLACE "${_TB_NL}" ";${_TB_ETX}" _lines "${_TB_ETX}${_raw}")
    set(${OUT_LINES_VAR} "${_lines}" PARENT_SCOPE)
endfunction()

macro(_tb_unescape_line LINE_VAR)
    string(SUBSTRING "${${LINE_VAR}}" 1 -1 ${LINE_VAR})
    string(REPLACE "${_TB_ENQ}" "${_TB_RBRACK}" ${LINE_VAR} "${${LINE_VAR}}")
    string(REPLACE "${_TB_EOT}" "${_TB_LBRACK}" ${LINE_VAR} "${${LINE_VAR}}")
    string(REPLACE "${_TB_STX}" ";" ${LINE_VAR} "${${LINE_VAR}}")
    string(REPLACE "${_TB_SOH}" "${_TB_BS}" ${LINE_VAR} "${${LINE_VAR}}")
endmacro()

# -----------------------------------------------------------------------------
# toybox_ensure_source(
#   DEST_DIR <dir>
#   [COMMIT <sha>]
#   [REPO_URLS <url1> <url2> ...]
#   [RETRIES_PER_URL <n>]
#   [RETRY_DELAY_SEC <sec>]
# )
# -----------------------------------------------------------------------------
function(toybox_ensure_source)
    set(_options "")
    set(_one_value_args DEST_DIR COMMIT RETRIES_PER_URL RETRY_DELAY_SEC)
    set(_multi_value_args REPO_URLS)
    cmake_parse_arguments(ARG "${_options}" "${_one_value_args}" "${_multi_value_args}" ${ARGN})

    if(NOT ARG_DEST_DIR)
        message(FATAL_ERROR "toybox_ensure_source: DEST_DIR is required")
    endif()
    if(NOT ARG_COMMIT)
        set(ARG_COMMIT "${TOYBOX_DEFAULT_REV}")
    endif()
    if(NOT DEFINED ARG_REPO_URLS)
        set(ARG_REPO_URLS ${TOYBOX_DEFAULT_REPOS})
    endif()
    if(NOT DEFINED ARG_RETRIES_PER_URL)
        set(ARG_RETRIES_PER_URL 3)
    endif()
    if(NOT DEFINED ARG_RETRY_DELAY_SEC)
        set(ARG_RETRY_DELAY_SEC 2)
    endif()

    get_filename_component(_resolved "${ARG_DEST_DIR}" ABSOLUTE)
    if(EXISTS "${_resolved}/toys.h" AND EXISTS "${_resolved}/main.c")
        return()
    endif()

    set(_errors "")
    foreach(_url IN LISTS ARG_REPO_URLS)
        foreach(_attempt RANGE 1 ${ARG_RETRIES_PER_URL})
            if(EXISTS "${_resolved}")
                file(REMOVE_RECURSE "${_resolved}")
            endif()
            file(MAKE_DIRECTORY "${_resolved}")

            execute_process(
                COMMAND git init "${_resolved}"
                RESULT_VARIABLE _init_rc
                OUTPUT_VARIABLE _init_out
                ERROR_VARIABLE _init_err
                OUTPUT_STRIP_TRAILING_WHITESPACE
                ERROR_STRIP_TRAILING_WHITESPACE
            )
            execute_process(
                COMMAND git -C "${_resolved}"
                        -c http.lowSpeedLimit=1000
                        -c http.lowSpeedTime=30
                        fetch --depth 1 --no-tags "${_url}" "${ARG_COMMIT}"
                RESULT_VARIABLE _fetch_rc
                OUTPUT_VARIABLE _fetch_out
                ERROR_VARIABLE _fetch_err
                OUTPUT_STRIP_TRAILING_WHITESPACE
                ERROR_STRIP_TRAILING_WHITESPACE
            )
            if(_init_rc EQUAL 0 AND _fetch_rc EQUAL 0)
                execute_process(
                    COMMAND git -C "${_resolved}" checkout --force FETCH_HEAD
                    RESULT_VARIABLE _co_rc
                    OUTPUT_VARIABLE _co_out
                    ERROR_VARIABLE _co_err
                    OUTPUT_STRIP_TRAILING_WHITESPACE
                    ERROR_STRIP_TRAILING_WHITESPACE
                )
                if(_co_rc EQUAL 0 AND EXISTS "${_resolved}/toys.h")
                    return()
                endif()
                list(APPEND _errors "${_url} (shallow checkout attempt ${_attempt}): ${_co_err}")
            else()
                list(APPEND _errors "${_url} (shallow fetch attempt ${_attempt}): ${_fetch_err}")
            endif()

            if(ARG_RETRY_DELAY_SEC GREATER 0)
                math(EXPR _sleep_sec "${ARG_RETRY_DELAY_SEC} * ${_attempt}")
                execute_process(COMMAND "${CMAKE_COMMAND}" -E sleep "${_sleep_sec}")
            endif()
        endforeach()
    endforeach()

    if(_errors)
        string(JOIN "; " _joined_errors ${_errors})
    else()
        set(_joined_errors "no repository URLs configured")
    endif()
    message(FATAL_ERROR "Failed to fetch upstream toybox (${ARG_COMMIT}): ${_joined_errors}")
endfunction()

# -----------------------------------------------------------------------------
# toybox_parse_version(<toys_h_text> <out_version>)
# -----------------------------------------------------------------------------
function(toybox_parse_version TOYS_H_TEXT OUT_VERSION)
    set(_version "0.8.15")
    string(REGEX MATCH "#define[ ${_TB_TAB}]+TOYBOX_VERSION[ ${_TB_TAB}]+${_TB_DQ}([^${_TB_DQ}]+)${_TB_DQ}" _match "${TOYS_H_TEXT}")
    if(_match)
        string(STRIP "${CMAKE_MATCH_1}" _version)
    endif()
    set(${OUT_VERSION} "${_version}" PARENT_SCOPE)
endfunction()

# -----------------------------------------------------------------------------
# Internal Helper: Return sorted list of toys/*/*.c absolute paths
# -----------------------------------------------------------------------------
function(_tb_get_toy_source_files TOYBOX_DIR OUT_FILES_VAR)
    file(GLOB _toy_files "${TOYBOX_DIR}/toys/*/*.c")
    if(_toy_files)
        list(SORT _toy_files)
    endif()
    set(${OUT_FILES_VAR} "${_toy_files}" PARENT_SCOPE)
endfunction()

# -----------------------------------------------------------------------------
# Internal Helper: Collect all Kconfig and CFG_/USE_/SKIP_ symbols
# -----------------------------------------------------------------------------
function(_tb_collect_all_config_symbols TOYBOX_DIR OUT_SYMBOLS_VAR)
    set(_symbols
        ${TOYBOX_COMMON_ENABLED_SYMBOLS}
        ${TOYBOX_WINDOWS_EXTRA_SYMBOLS}
        ${TOYBOX_INT_SYMBOLS}
    )

    set(_scan_files "")
    if(EXISTS "${TOYBOX_DIR}/Config.in")
        list(APPEND _scan_files "${TOYBOX_DIR}/Config.in")
    endif()
    file(GLOB _root_h "${TOYBOX_DIR}/*.h")
    file(GLOB _root_c "${TOYBOX_DIR}/*.c")
    file(GLOB _lib_h "${TOYBOX_DIR}/lib/*.h")
    file(GLOB _lib_c "${TOYBOX_DIR}/lib/*.c")
    _tb_get_toy_source_files("${TOYBOX_DIR}" _toy_c)
    list(APPEND _scan_files ${_root_h} ${_root_c} ${_lib_h} ${_lib_c} ${_toy_c})

    foreach(_fpath IN LISTS _scan_files)
        if(EXISTS "${_fpath}")
            file(READ "${_fpath}" _content)
            string(REPLACE ";" " " _content "${_content}")
            string(REGEX MATCHALL "(^|${_TB_NL})[ ${_TB_TAB}]*config[ ${_TB_TAB}]+([A-Z0-9_]+)[ ${_TB_TAB}]*(${_TB_NL}|$)" _cfg_matches "${_content}")
            foreach(_m IN LISTS _cfg_matches)
                string(REGEX REPLACE "^.*config[ ${_TB_TAB}]+([A-Z0-9_]+).*$" "${_TB_BS}1" _sym "${_m}")
                list(APPEND _symbols "${_sym}")
            endforeach()

            string(REGEX MATCHALL "(^|[^A-Za-z0-9_])(CFG|USE|SKIP)_([A-Z0-9_]+)" _macro_matches "${_content}")
            foreach(_m IN LISTS _macro_matches)
                string(REGEX REPLACE "^.*(CFG|USE|SKIP)_([A-Z0-9_]+)$" "${_TB_BS}2" _sym "${_m}")
                list(APPEND _symbols "${_sym}")
            endforeach()
        endif()
    endforeach()

    list(REMOVE_DUPLICATES _symbols)
    list(SORT _symbols)
    set(${OUT_SYMBOLS_VAR} "${_symbols}" PARENT_SCOPE)
endfunction()

# -----------------------------------------------------------------------------
# Internal Helper: Generate generated/config.h
# -----------------------------------------------------------------------------
function(_tb_generate_config_h ALL_SYMBOLS ENABLED_SYMBOLS OUT_TEXT_VAR)
    set(_lines
        "/* Generated by toybox-windows GenerateToyboxHeaders.cmake */"
        "#ifndef TOYBOX_GENERATED_CONFIG_H"
        "#define TOYBOX_GENERATED_CONFIG_H"
        "${_TB_SOH}"
    )
    foreach(_sym IN LISTS ALL_SYMBOLS)
        list(FIND TOYBOX_INT_SYMBOLS "${_sym}" _int_idx)
        if(NOT _int_idx EQUAL -1)
            set(_int_val "${TOYBOX_INT_VAL_${_sym}}")
            list(APPEND _lines
                "#define CFG_${_sym} ${_int_val}"
                "#define USE_${_sym}(...) __VA_ARGS__"
                "#define SKIP_${_sym}(...)"
            )
        else()
            list(FIND ENABLED_SYMBOLS "${_sym}" _en_idx)
            if(NOT _en_idx EQUAL -1)
                list(APPEND _lines
                    "#define CFG_${_sym} 1"
                    "#define USE_${_sym}(...) __VA_ARGS__"
                    "#define SKIP_${_sym}(...)"
                )
            else()
                list(APPEND _lines
                    "#define CFG_${_sym} 0"
                    "#define USE_${_sym}(...)"
                    "#define SKIP_${_sym}(...) __VA_ARGS__"
                )
            endif()
        endif()
    endforeach()
    list(APPEND _lines "${_TB_SOH}" "#endif /* TOYBOX_GENERATED_CONFIG_H */")
    string(JOIN "${_TB_NL}" _out ${_lines})
    string(REPLACE "${_TB_SOH}" "" _out "${_out}")
    string(APPEND _out "${_TB_NL}")
    set(${OUT_TEXT_VAR} "${_out}" PARENT_SCOPE)
endfunction()

# -----------------------------------------------------------------------------
# Internal Helper:Classify option char according to scripts/mkflags.c chrtype()
# -----------------------------------------------------------------------------
function(_tb_chrtype CH OUT_TYPE_VAR)
    if("${CH}" STREQUAL "^" OR "${CH}" STREQUAL "-" OR "${CH}" STREQUAL ":"
       OR "${CH}" STREQUAL "#" OR "${CH}" STREQUAL "|" OR "${CH}" STREQUAL "@"
       OR "${CH}" STREQUAL "*" OR "${CH}" STREQUAL ";" OR "${CH}" STREQUAL " "
       OR "${CH}" STREQUAL "%" OR "${CH}" STREQUAL ".")
        set(${OUT_TYPE_VAR} 1 PARENT_SCOPE)
    elseif("${CH}" STREQUAL "=" OR "${CH}" STREQUAL "<" OR "${CH}" STREQUAL ">")
        set(${OUT_TYPE_VAR} 2 PARENT_SCOPE)
    elseif("${CH}" STREQUAL "?" OR "${CH}" STREQUAL "&" OR "${CH}" STREQUAL "0")
        set(${OUT_TYPE_VAR} 3 PARENT_SCOPE)
    else()
        set(${OUT_TYPE_VAR} 0 PARENT_SCOPE)
    endif()
endfunction()

# -----------------------------------------------------------------------------
# Internal Helper: Decode octal escapes (octane() in scripts/mkflags.c)
# Represents high-bit bytes (>=128) or \001 using @X<HEX>@ token if needed, or
# raw ASCII char for 1..127. For high-bit octals (e.g. \200..), encodes as
# \x02<2-hex-digits> so string(SUBSTRING) keeps 1-character indexing when we
# map to a single high-bit placeholder char or we decode directly via ASCII!
# Wait: string(ASCII <code> _ch) produces a 1-byte Latin-1 character for 1..255!
# Let's check if CMake string(LENGTH) / string(SUBSTRING) works on Latin-1 or
# if we should use a 1-char placeholder for >=128.
# -----------------------------------------------------------------------------
function(_tb_octane INPUT_STR OUT_STR_VAR)
    # Fast path if no backslash is present
    string(FIND "${INPUT_STR}" "${_TB_BS}" _bs_pos)
    if(_bs_pos EQUAL -1)
        set(${OUT_STR_VAR} "${INPUT_STR}" PARENT_SCOPE)
        return()
    endif()

    string(LENGTH "${INPUT_STR}" _len)
    set(_idx 0)
    set(_out "")
    while(_idx LESS _len)
        string(SUBSTRING "${INPUT_STR}" ${_idx} 1 _ch)
        if("${_ch}" STREQUAL "${_TB_BS}")
            set(_val 0)
            math(EXPR _idx "${_idx} + 1")
            while(_idx LESS _len)
                string(SUBSTRING "${INPUT_STR}" ${_idx} 1 _d)
                if("${_d}" MATCHES "^[0-7]$")
                    math(EXPR _val "(${_val} * 8) + ${_d}")
                    math(EXPR _idx "${_idx} + 1")
                else()
                    break()
                endif()
            endwhile()
            math(EXPR _val "${_val} & 255")
            if(_val GREATER 127)
                math(EXPR _low7 "${_val} & 127")
                math(EXPR _hi "(${_low7} >> 4) & 15")
                math(EXPR _lo "${_low7} & 15")
                string(SUBSTRING "0123456789ABCDEF" ${_hi} 1 _h1)
                string(SUBSTRING "0123456789ABCDEF" ${_lo} 1 _h2)
                set(_hex "${_h1}${_h2}")
                get_property(_hcount GLOBAL PROPERTY _TB_HIGH_COUNT)
                if(NOT _hcount)
                    set(_hcount 0)
                endif()
                math(EXPR _hSlot "${_hcount} + 14")
                if(_hSlot GREATER 31)
                    set(_hSlot 14)
                    set(_hcount 0)
                else()
                    math(EXPR _hcount "${_hcount} + 1")
                endif()
                set_property(GLOBAL PROPERTY _TB_HIGH_COUNT "${_hcount}")
                set_property(GLOBAL PROPERTY _TB_HIGH_HEX_${_hSlot} "X${_hex}")
                math(EXPR _u1 "192 + (${_val} >> 6)")
                math(EXPR _u2 "128 + (${_val} & 63)")
                string(ASCII ${_u1} ${_u2} _utf8_ch)
                set_property(GLOBAL PROPERTY _TB_HIGH_UTF8_${_hSlot} "${_utf8_ch}")
                string(ASCII ${_hSlot} _slot_ch)
                string(APPEND _out "${_slot_ch}")
            elseif(_val GREATER 0)
                string(ASCII ${_val} _dec_ch)
                string(APPEND _out "${_dec_ch}")
            endif()
        else()
            string(APPEND _out "${_ch}")
            math(EXPR _idx "${_idx} + 1")
        endif()
    endwhile()
    set(${OUT_STR_VAR} "${_out}" PARENT_SCOPE)
endfunction()

# -----------------------------------------------------------------------------
# Internal Helper: Evaluate USE_*("...") and SKIP_*("...") in NEWTOY optstring
# -----------------------------------------------------------------------------
function(_tb_evaluate_optstring RAW_MIDDLE ENABLED_SYMBOLS ALLYES OUT_STR_VAR)
    string(STRIP "${RAW_MIDDLE}" _stripped)
    if("${_stripped}" STREQUAL "0")
        set(${OUT_STR_VAR} " " PARENT_SCOPE)
        return()
    endif()

    set(_work "${_stripped}")
    # Repeatedly replace USE_SYM("...") and SKIP_SYM("...") macros
    set(_changed TRUE)
    while(_changed)
        set(_changed FALSE)
        if("${_work}" MATCHES "(USE|SKIP)_([A-Z0-9_]+)${_TB_BS}(${_TB_DQ}([^${_TB_DQ}]*)${_TB_DQ}${_TB_BS})")
            set(_kind "${CMAKE_MATCH_1}")
            set(_sym "${CMAKE_MATCH_2}")
            set(_inner "${CMAKE_MATCH_3}")
            set(_full_match "${CMAKE_MATCH_0}")
            if(ALLYES)
                set(_rep "${_TB_DQ}${_inner}${_TB_DQ}")
            else()
                list(FIND ENABLED_SYMBOLS "${_sym}" _idx)
                if(("${_kind}" STREQUAL "USE" AND NOT _idx EQUAL -1)
                   OR ("${_kind}" STREQUAL "SKIP" AND _idx EQUAL -1))
                    set(_rep "${_TB_DQ}${_inner}${_TB_DQ}")
                else()
                    set(_rep "${_TB_DQ}${_TB_DQ}")
                endif()
            endif()
            string(REPLACE "${_full_match}" "${_rep}" _work "${_work}")
            set(_changed TRUE)
        endif()
    endwhile()

    # Concatenate all quoted string literals "..."
    set(_joined "")
    string(LENGTH "${_work}" _wlen)
    set(_wi 0)
    set(_in_q FALSE)
    while(_wi LESS _wlen)
        string(SUBSTRING "${_work}" ${_wi} 1 _c)
        if("${_c}" STREQUAL "${_TB_DQ}")
            if(_in_q)
                set(_in_q FALSE)
            else()
                set(_in_q TRUE)
            endif()
        elseif(_in_q)
            string(APPEND _joined "${_c}")
        endif()
        math(EXPR _wi "${_wi} + 1")
    endwhile()

    if("${_joined}" STREQUAL "")
        set(${OUT_STR_VAR} " " PARENT_SCOPE)
    else()
        set(${OUT_STR_VAR} "${_joined}" PARENT_SCOPE)
    endif()
endfunction()

# -----------------------------------------------------------------------------
# Internal Helper: Replicate mark_gaps(flags, allflags) from scripts/mkflags.c
# -----------------------------------------------------------------------------
function(_tb_mark_gaps FLAGS ALLFLAGS OUT_MGAPS_VAR)
    string(REGEX REPLACE "^[ ${_TB_TAB}]+" "" _flags_s "${FLAGS}")
    string(REGEX REPLACE "^[ ${_TB_TAB}]+" "" _all_s "${ALLFLAGS}")

    if("${_flags_s}" STREQUAL "${_all_s}")
        set(${OUT_MGAPS_VAR} "${_all_s}" PARENT_SCOPE)
        return()
    endif()

    string(LENGTH "${_flags_s}" _flen)
    string(LENGTH "${_all_s}" _alen)
    set(_out "")
    set(_bare TRUE)
    set(_fi 0)
    set(_ai 0)

    while(_ai LESS _alen)
        string(SUBSTRING "${_all_s}" ${_ai} 1 _ch)
        if("${_ch}" STREQUAL "(")
            string(SUBSTRING "${_all_s}" ${_ai} -1 _rem_all)
            string(FIND "${_rem_all}" ")" _rel_end)
            if(NOT _rel_end EQUAL -1)
                math(EXPR _span "${_rel_end} + 1")
            else()
                math(EXPR _span "${_alen} - ${_ai}")
            endif()
            string(SUBSTRING "${_all_s}" ${_ai} ${_span} _sub)
            set(_fsub "")
            math(EXPR _f_avail "${_flen} - ${_fi}")
            if(_f_avail GREATER_EQUAL _span)
                string(SUBSTRING "${_flags_s}" ${_fi} ${_span} _fsub)
            elseif(_f_avail GREATER 0)
                string(SUBSTRING "${_flags_s}" ${_fi} ${_f_avail} _fsub)
            endif()
            if(NOT "${_fsub}" STREQUAL "${_sub}")
                if(_bare)
                    string(APPEND _out "${_TB_SOH}")
                endif()
            else()
                string(APPEND _out "${_sub}")
                math(EXPR _fi "${_fi} + ${_span}")
            endif()
            math(EXPR _ai "${_ai} + ${_span}")
        else()
            math(EXPR _ai "${_ai} + 1")
            _tb_chrtype("${_ch}" _ct)
            if(_bare AND _ct EQUAL 0)
                set(_bare FALSE)
            endif()
            set(_fch "")
            if(_fi LESS _flen)
                string(SUBSTRING "${_flags_s}" ${_fi} 1 _fch)
            endif()
            if(_fi LESS _flen AND "${_fch}" STREQUAL "${_ch}")
                string(APPEND _out "${_ch}")
                math(EXPR _fi "${_fi} + 1")
            else()
                if(_ct EQUAL 0 OR (NOT _bare AND _ct EQUAL 3))
                    string(APPEND _out "${_TB_SOH}")
                elseif(_ct EQUAL 2)
                    while(_ai LESS _alen)
                        string(SUBSTRING "${_all_s}" ${_ai} 1 _d)
                        if("${_d}" MATCHES "^[0-9]$")
                            math(EXPR _ai "${_ai} + 1")
                        else()
                            break()
                        endif()
                    endwhile()
                endif()
            endif()
        endif()
    endwhile()

    set(${OUT_MGAPS_VAR} "${_out}" PARENT_SCOPE)
endfunction()

# -----------------------------------------------------------------------------
# Internal Helper: Replicate digest(optstring) from scripts/mkflags.c
# Populates two parallel lists (ordered right-to-left, LSB first):
#   OUT_CMDS_VAR: short option char, "~", or "NONE" (for bare longopt)
#   OUT_LOPTS_VAR: primary (first attached) longopt name or ""
# -----------------------------------------------------------------------------
function(_tb_digest_optstring OPTSTRING OUT_CMDS_VAR OUT_LOPTS_VAR)
    string(REGEX REPLACE "^[ ${_TB_TAB}]+" "" _str "${OPTSTRING}")
    string(LENGTH "${_str}" _len)
    set(_cmds "")
    set(_lopts "")
    set(_idx 0)

    while(_idx LESS _len)
        string(SUBSTRING "${_str}" ${_idx} 1 _ch)
        if("${_ch}" STREQUAL "${_TB_LBRACK}")
            break()
        endif()
        if("${_ch}" STREQUAL "(")
            math(EXPR _next_idx "${_idx} + 1")
            if(_next_idx LESS _len)
                string(SUBSTRING "${_str}" ${_next_idx} 1 _nch)
                if("${_nch}" STREQUAL ")")
                    message(FATAL_ERROR "empty () longopt in '${_str}'")
                endif()
            endif()
            string(SUBSTRING "${_str}" ${_next_idx} -1 _rem)
            string(FIND "${_rem}" ")" _rel_end)
            if(_rel_end EQUAL -1)
                message(FATAL_ERROR "unterminated (longopt in '${_str}'")
            endif()
            string(SUBSTRING "${_rem}" 0 ${_rel_end} _lopt_name)
            string(REPLACE "-" "_" _lopt_name "${_lopt_name}")
            math(EXPR _idx "${_next_idx} + ${_rel_end} + 1")

            list(LENGTH _cmds _clen)
            if(_clen GREATER 0)
                list(GET _cmds 0 _head_cmd)
                if(NOT "${_head_cmd}" STREQUAL "NONE")
                    list(REMOVE_AT _lopts 0)
                    list(INSERT _lopts 0 "${_lopt_name}")
                else()
                    list(INSERT _cmds 0 "NONE")
                    list(INSERT _lopts 0 "${_lopt_name}")
                endif()
            else()
                list(INSERT _cmds 0 "NONE")
                list(INSERT _lopts 0 "${_lopt_name}")
            endif()
        else()
            _tb_chrtype("${_ch}" _ct)
            list(LENGTH _cmds _clen)
            if(_ct EQUAL 1 OR (_ct EQUAL 3 AND _clen EQUAL 0))
                math(EXPR _idx "${_idx} + 1")
            elseif(_ct EQUAL 2)
                math(EXPR _next_idx "${_idx} + 1")
                if(_next_idx LESS _len)
                    string(SUBSTRING "${_str}" ${_next_idx} 1 _nch)
                    if("${_nch}" STREQUAL "-")
                        math(EXPR _idx "${_idx} + 1")
                        math(EXPR _next_idx "${_idx} + 1")
                    endif()
                endif()
                if(_next_idx GREATER_EQUAL _len)
                    message(FATAL_ERROR "${_ch} without number in '${_str}'")
                endif()
                string(SUBSTRING "${_str}" ${_next_idx} 1 _dch)
                if(NOT "${_dch}" MATCHES "^[0-9]$")
                    message(FATAL_ERROR "${_ch} without number in '${_str}'")
                endif()
                math(EXPR _idx "${_idx} + 1")
                while(_idx LESS _len)
                    string(SUBSTRING "${_str}" ${_idx} 1 _d)
                    if("${_d}" MATCHES "^[0-9]$")
                        if(_clen EQUAL 0)
                            math(EXPR _idx "${_idx} + 1")
                            break()
                        endif()
                        math(EXPR _idx "${_idx} + 1")
                    else()
                        break()
                    endif()
                endwhile()
            else()
                if("${_ch}" STREQUAL "~")
                    math(EXPR _next_idx "${_idx} + 1")
                    set(_nch "")
                    if(_next_idx LESS _len)
                        string(SUBSTRING "${_str}" ${_next_idx} 1 _nch)
                    endif()
                    if(NOT "${_nch}" STREQUAL "(")
                        message(FATAL_ERROR "~ without (longopt) in '${_str}'")
                    endif()
                endif()
                if("${_ch}" STREQUAL ";")
                    list(INSERT _cmds 0 "${_TB_SOH}")
                else()
                    list(INSERT _cmds 0 "${_ch}")
                endif()
                list(INSERT _lopts 0 "NONE")
                math(EXPR _idx "${_idx} + 1")
            endif()
        endif()
    endwhile()

    set(${OUT_CMDS_VAR} "${_cmds}" PARENT_SCOPE)
    set(${OUT_LOPTS_VAR} "${_lopts}" PARENT_SCOPE)
endfunction()

# -----------------------------------------------------------------------------
# Internal Helper: Format FLAG_<sym> suffix for a node
# -----------------------------------------------------------------------------
function(_tb_format_flag_symbol CMD_STR LOPT_STR OUT_SYM_VAR)
    if("${CMD_STR}" STREQUAL "NONE" OR "${CMD_STR}" STREQUAL "~")
        set(${OUT_SYM_VAR} "${LOPT_STR}" PARENT_SCOPE)
        return()
    elseif("${CMD_STR}" STREQUAL "${_TB_SOH}")
        set(${OUT_SYM_VAR} ";" PARENT_SCOPE)
        return()
    endif()
    foreach(_slot RANGE 14 31)
        string(ASCII ${_slot} _sch)
        if("${CMD_STR}" STREQUAL "${_sch}")
            get_property(_hhex GLOBAL PROPERTY _TB_HIGH_HEX_${_slot})
            set(${OUT_SYM_VAR} "${_hhex}" PARENT_SCOPE)
            return()
        endif()
    endforeach()
    set(${OUT_SYM_VAR} "${CMD_STR}" PARENT_SCOPE)
endfunction()

# -----------------------------------------------------------------------------
# Internal Helper: Parse USE_*(NEWTOY/OLDTOY(...)) entries and generate
# newtoys.h, flags.h, and enabled toy source list
# -----------------------------------------------------------------------------
function(_tb_process_toys TOYBOX_DIR ENABLED_SYMBOLS OUT_NEWTOYS_VAR OUT_FLAGS_VAR OUT_ENABLED_SRCS_VAR)
    _tb_get_toy_source_files("${TOYBOX_DIR}" _toy_files)

    set(_sort_keys "")
    set(_seq 0)

    # First entry is always toybox multiplexer in main.c
    set(_entry_0_guard "TOYBOX")
    set(_entry_0_kind "NEW")
    set(_entry_0_name "toybox")
    set(_entry_0_middle "0")
    set(_entry_0_raw "USE_TOYBOX(NEWTOY(toybox, 0, TOYFLAG_STAYROOT|TOYFLAG_NOHELP))")
    set(_entry_0_src "main.c")

    set(_enabled_srcs "")

    foreach(_c_file IN LISTS _toy_files)
        file(RELATIVE_PATH _rel "${TOYBOX_DIR}" "${_c_file}")
        _tb_read_lines("${_c_file}" _lines)
        foreach(_enc_line IN LISTS _lines)
            set(_line "${_enc_line}")
            _tb_unescape_line(_line)
            if("${_line}" MATCHES "^USE_([A-Z0-9_]+)${_TB_BS}((NEW|OLD)TOY${_TB_BS}(([^,]+),[ ${_TB_TAB}]*(.+),[ ${_TB_TAB}]*([^,]+)${_TB_BS})${_TB_BS})$")
                set(_guard "${CMAKE_MATCH_1}")
                set(_kind "${CMAKE_MATCH_2}")
                string(STRIP "${CMAKE_MATCH_3}" _name)
                string(STRIP "${CMAKE_MATCH_4}" _middle)

                math(EXPR _seq "${_seq} + 1")
                # Pad sequence number to 5 digits so lexicographical sort is stable on name
                math(EXPR _pad_seq "100000 + ${_seq}")
                string(SUBSTRING "${_pad_seq}" 1 5 _seq_str)
                set(_safe_name "${_name}")
                string(REPLACE ";" "${_TB_STX}" _safe_name "${_safe_name}")
                string(REPLACE "${_TB_LBRACK}" "^" _safe_name "${_safe_name}")
                string(REPLACE "${_TB_RBRACK}" "^" _safe_name "${_safe_name}")
                list(APPEND _sort_keys "${_safe_name}${_TB_ACK}${_seq_str}${_TB_ACK}${_seq}")

                set(_entry_${_seq}_guard "${_guard}")
                set(_entry_${_seq}_kind "${_kind}")
                set(_entry_${_seq}_name "${_name}")
                set(_entry_${_seq}_middle "${_middle}")
                set(_entry_${_seq}_raw "${_line}")
                set(_entry_${_seq}_src "${_rel}")

                list(FIND ENABLED_SYMBOLS "${_guard}" _en_idx)
                if(NOT _en_idx EQUAL -1)
                    list(APPEND _enabled_srcs "${_rel}")
                endif()
            endif()
        endforeach()
    endforeach()

    if(_sort_keys)
        list(SORT _sort_keys)
    endif()
    if(_enabled_srcs)
        list(REMOVE_DUPLICATES _enabled_srcs)
        list(SORT _enabled_srcs)
    endif()

    set(_ordered_ids "0")
    foreach(_key IN LISTS _sort_keys)
        string(REGEX REPLACE "^.*${_TB_ACK}([0-9]+)$" "${_TB_BS}1" _id "${_key}")
        list(APPEND _ordered_ids "${_id}")
    endforeach()

    # Build newtoys.h and flags.h
    set(_newtoys_lines "")
    set(_flags_header
        "#undef FORCED_FLAG"
        "#ifdef FORCE_FLAGS"
        "#define FORCED_FLAG 1LL"
        "#else"
        "#define FORCED_FLAG 0LL"
        "#endif"
        "${_TB_ETX}"
    )
    set(_flags_body "")

    foreach(_id IN LISTS _ordered_ids)
        set(_raw "${_entry_${_id}_raw}")
        string(REPLACE ";" "${_TB_STX}" _safe_raw "${_raw}")
        string(REPLACE "${_TB_LBRACK}" "${_TB_EOT}" _safe_raw "${_safe_raw}")
        string(REPLACE "${_TB_RBRACK}" "${_TB_ENQ}" _safe_raw "${_safe_raw}")
        list(APPEND _newtoys_lines "${_safe_raw}")

        set(_kind "${_entry_${_id}_kind}")
        if("${_kind}" STREQUAL "NEW")
            set(_cmd "${_entry_${_id}_name}")
            set(_guard "${_entry_${_id}_guard}")
            set(_middle "${_entry_${_id}_middle}")

            list(FIND ENABLED_SYMBOLS "${_guard}" _en_idx)
            if(NOT _en_idx EQUAL -1)
                _tb_evaluate_optstring("${_middle}" "${ENABLED_SYMBOLS}" FALSE _flags_raw)
            else()
                set(_flags_raw " ")
            endif()
            _tb_evaluate_optstring("${_middle}" "${ENABLED_SYMBOLS}" TRUE _allflags_raw)

            set_property(GLOBAL PROPERTY _TB_HIGH_COUNT 0)
            _tb_octane("${_flags_raw}" _flags)
            set_property(GLOBAL PROPERTY _TB_HIGH_COUNT 0)
            _tb_octane("${_allflags_raw}" _allflags)

            set(_comment_line "// ${_cmd} ${_flags} ${_allflags}")
            foreach(_slot RANGE 14 31)
                string(ASCII ${_slot} _sch)
                get_property(_u8 GLOBAL PROPERTY _TB_HIGH_UTF8_${_slot})
                if(_u8)
                    string(REPLACE "${_sch}" "${_u8}" _comment_line "${_comment_line}")
                endif()
            endforeach()
            string(REPLACE ";" "${_TB_STX}" _comment_line "${_comment_line}")
            string(REPLACE "${_TB_LBRACK}" "${_TB_EOT}" _comment_line "${_comment_line}")
            string(REPLACE "${_TB_RBRACK}" "${_TB_ENQ}" _comment_line "${_comment_line}")
            list(APPEND _flags_header "${_comment_line}")

            set(_has_mgaps FALSE)
            set(_mgaps "")
            if(NOT "${_flags}" STREQUAL " ")
                _tb_mark_gaps("${_flags}" "${_allflags}" _mgaps)
                set(_has_mgaps TRUE)
            elseif(NOT "${_allflags}" STREQUAL " ")
                set(_mgaps "${_allflags}")
                set(_has_mgaps TRUE)
            endif()

            list(APPEND _flags_header "#undef OPTSTR_${_cmd}")
            if(_has_mgaps)
                string(REPLACE "${_TB_SOH}" "${_TB_BS}001" _esc_mgaps "${_mgaps}")
                foreach(_slot RANGE 14 31)
                    string(ASCII ${_slot} _sch)
                    get_property(_u8 GLOBAL PROPERTY _TB_HIGH_UTF8_${_slot})
                    if(_u8)
                        string(REPLACE "${_sch}" "${_u8}" _esc_mgaps "${_esc_mgaps}")
                    endif()
                endforeach()
                string(REPLACE ";" "${_TB_STX}" _esc_mgaps "${_esc_mgaps}")
                string(REPLACE "${_TB_LBRACK}" "${_TB_EOT}" _esc_mgaps "${_esc_mgaps}")
                string(REPLACE "${_TB_RBRACK}" "${_TB_ENQ}" _esc_mgaps "${_esc_mgaps}")
                list(APPEND _flags_header "#define OPTSTR_${_cmd} ${_TB_DQ}${_esc_mgaps}${_TB_DQ}")
            else()
                list(APPEND _flags_header "#define OPTSTR_${_cmd} 0")
            endif()

            _tb_digest_optstring("${_flags}" _flist_cmds _flist_lopts)
            _tb_digest_optstring("${_allflags}" _aflist_cmds _aflist_lopts)

            list(APPEND _flags_header
                "#ifdef CLEANUP_${_cmd}"
                "#undef CLEANUP_${_cmd}"
                "#undef FOR_${_cmd}"
            )
            list(LENGTH _aflist_cmds _alen)
            if(_alen GREATER 0)
                math(EXPR _amax "${_alen} - 1")
                foreach(_ai RANGE 0 ${_amax})
                    list(GET _aflist_cmds ${_ai} _acmd)
                    list(GET _aflist_lopts ${_ai} _alopt)
                    _tb_format_flag_symbol("${_acmd}" "${_alopt}" _fsym)
                    string(REPLACE ";" "${_TB_STX}" _fsym "${_fsym}")
                    list(APPEND _flags_header "#undef FLAG_${_fsym}")
                endforeach()
            endif()
            list(APPEND _flags_header "#endif" "${_TB_ETX}")

            list(APPEND _flags_body
                "#ifdef FOR_${_cmd}"
                "#define CLEANUP_${_cmd}"
                "#ifndef TT"
                "#define TT this.${_cmd}"
                "#endif"
            )

            set(_flist_idx 0)
            set(_bit 0)
            list(LENGTH _flist_cmds _flen)
            if(_alen GREATER 0)
                math(EXPR _amax "${_alen} - 1")
                foreach(_ai RANGE 0 ${_amax})
                    list(GET _aflist_cmds ${_ai} _acmd)
                    list(GET _aflist_lopts ${_ai} _alopt)
                    _tb_format_flag_symbol("${_acmd}" "${_alopt}" _fsym)
                    string(REPLACE ";" "${_TB_STX}" _fsym "${_fsym}")

                    set(_flag_enabled FALSE)
                    if(_flist_idx LESS _flen)
                        list(GET _flist_cmds ${_flist_idx} _fcmd)
                        list(GET _flist_lopts ${_flist_idx} _flopt)
                        if("${_acmd}" STREQUAL "NONE" OR "${_acmd}" STREQUAL "~")
                            if(NOT "${_flopt}" STREQUAL "NONE" AND "${_flopt}" STREQUAL "${_alopt}")
                                set(_flag_enabled TRUE)
                            endif()
                        else()
                            if("${_fcmd}" STREQUAL "${_acmd}")
                                set(_flag_enabled TRUE)
                            endif()
                        endif()
                    endif()

                    if(_flag_enabled)
                        set(_shift_base "1LL")
                        math(EXPR _flist_idx "${_flist_idx} + 1")
                    else()
                        set(_shift_base "FORCED_FLAG")
                    endif()
                    list(APPEND _flags_body "#define FLAG_${_fsym} (${_shift_base}<<${_bit})")
                    math(EXPR _bit "${_bit} + 1")
                endforeach()
            endif()
            list(APPEND _flags_body "#endif" "${_TB_ETX}")
        endif()
    endforeach()

    string(JOIN "${_TB_NL}" _newtoys_text ${_newtoys_lines})
    string(REPLACE "${_TB_ENQ}" "${_TB_RBRACK}" _newtoys_text "${_newtoys_text}")
    string(REPLACE "${_TB_EOT}" "${_TB_LBRACK}" _newtoys_text "${_newtoys_text}")
    string(REPLACE "${_TB_STX}" ";" _newtoys_text "${_newtoys_text}")
    string(APPEND _newtoys_text "${_TB_NL}")

    list(APPEND _flags_header ${_flags_body})
    string(JOIN "${_TB_NL}" _flags_text ${_flags_header})
    string(REPLACE "${_TB_ETX}" "" _flags_text "${_flags_text}")
    string(REPLACE "${_TB_ENQ}" "${_TB_RBRACK}" _flags_text "${_flags_text}")
    string(REPLACE "${_TB_EOT}" "${_TB_LBRACK}" _flags_text "${_flags_text}")
    string(REPLACE "${_TB_STX}" ";" _flags_text "${_flags_text}")

    set(${OUT_NEWTOYS_VAR} "${_newtoys_text}" PARENT_SCOPE)
    set(${OUT_FLAGS_VAR} "${_flags_text}" PARENT_SCOPE)
    set(${OUT_ENABLED_SRCS_VAR} "${_enabled_srcs}" PARENT_SCOPE)
endfunction()

# -----------------------------------------------------------------------------
# Internal Helper: Promote top-level long fields in GLOBALS(...) to intptr_t
# -----------------------------------------------------------------------------
function(_tb_promote_globals_long LINE_STR OUT_LINE_VAR)
    set(_line "${LINE_STR}")
    if("${_line}" MATCHES "^([ ${_TB_TAB}]*)long[ ${_TB_TAB}]+([^;]+;[ ${_TB_TAB}]*)$")
        set(_indent "${CMAKE_MATCH_1}")
        set(_rest "${CMAKE_MATCH_2}")
        if(NOT "${_rest}" MATCHES "^long[ ${_TB_TAB}]")
            set(_line "${_indent}intptr_t ${_rest}")
        endif()
    endif()
    set(${OUT_LINE_VAR} "${_line}" PARENT_SCOPE)
endfunction()

# -----------------------------------------------------------------------------
# Internal Helper: Generate generated/globals.h and generated/tags.h
# -----------------------------------------------------------------------------
function(_tb_generate_globals_and_tags TOYBOX_DIR OUT_GLOBALS_VAR OUT_TAGS_VAR)
    _tb_get_toy_source_files("${TOYBOX_DIR}" _toy_files)

    set(_struct_blocks "")
    set(_union_members "")
    set(_seen_structs "")
    set(_tag_lines "")
    set(_spaces "                                ")

    foreach(_c_file IN LISTS _toy_files)
        file(READ "${_c_file}" _raw_file)
        # Fast check if file has GLOBALS( or TAGGED_ARRAY(
        string(FIND "${_raw_file}" "GLOBALS(" _g_pos)
        string(FIND "${_raw_file}" "TAGGED_ARRAY(" _t_pos)
        if(_g_pos EQUAL -1 AND _t_pos EQUAL -1)
            continue()
        endif()

        _tb_read_lines("${_c_file}" _lines)
        set(_for_name "")
        set(_in_globals FALSE)
        set(_body_lines "")
        set(_has_non_empty_body FALSE)

        set(_in_tagged FALSE)
        set(_tag_head "")
        set(_tag_idx 0)

        foreach(_enc_line IN LISTS _lines)
            set(_line "${_enc_line}")
            _tb_unescape_line(_line)

            if("${_line}" MATCHES "^#define[ ${_TB_TAB}]+FOR_([A-Za-z0-9_]+)")
                set(_for_name "${CMAKE_MATCH_1}")
            endif()

            if("${_line}" MATCHES "^GLOBALS${_TB_BS}((.*)$")
                set(_in_globals TRUE)
                set(_first_body "${CMAKE_MATCH_1}")
                _tb_promote_globals_long("${_first_body}" _first_body)
                string(STRIP "${_first_body}" _fb_strip)
                if(NOT "${_fb_strip}" STREQUAL "")
                    set(_has_non_empty_body TRUE)
                else()
                    set(_has_non_empty_body FALSE)
                endif()
                string(REPLACE ";" "${_TB_STX}" _safe_fb "${_first_body}")
                string(REPLACE "${_TB_LBRACK}" "${_TB_EOT}" _safe_fb "${_safe_fb}")
                string(REPLACE "${_TB_RBRACK}" "${_TB_ENQ}" _safe_fb "${_safe_fb}")
                if("${_safe_fb}" STREQUAL "")
                    set(_safe_fb "${_TB_ETX}")
                endif()
                set(_body_lines "${_safe_fb}")
            elseif(_in_globals)
                if("${_line}" MATCHES "^${_TB_BS})")
                    set(_in_globals FALSE)
                    if(NOT "${_for_name}" STREQUAL "")
                        list(FIND _seen_structs "${_for_name}" _sidx)
                        if(_sidx EQUAL -1)
                            list(APPEND _seen_structs "${_for_name}")
                            if(NOT _has_non_empty_body)
                                set(_body_lines "  int _dummy${_TB_STX}")
                            endif()
                            string(JOIN "${_TB_NL}" _joined_body ${_body_lines})
                            list(APPEND _struct_blocks "struct ${_for_name}_data {${_TB_NL}${_joined_body}${_TB_NL}}${_TB_STX}${_TB_NL}")
                            list(APPEND _union_members "${_TB_TAB}struct ${_for_name}_data ${_for_name}${_TB_STX}")
                        endif()
                    endif()
                    set(_body_lines "")
                else()
                    _tb_promote_globals_long("${_line}" _pline)
                    string(STRIP "${_pline}" _p_strip)
                    if(NOT "${_p_strip}" STREQUAL "")
                        set(_has_non_empty_body TRUE)
                    endif()
                    string(REPLACE ";" "${_TB_STX}" _safe_pl "${_pline}")
                    string(REPLACE "${_TB_LBRACK}" "${_TB_EOT}" _safe_pl "${_safe_pl}")
                    string(REPLACE "${_TB_RBRACK}" "${_TB_ENQ}" _safe_pl "${_safe_pl}")
                    if("${_safe_pl}" STREQUAL "")
                        set(_safe_pl "${_TB_ETX}")
                    endif()
                    list(APPEND _body_lines "${_safe_pl}")
                endif()
            endif()

            if("${_line}" MATCHES "TAGGED_ARRAY${_TB_BS}(([^,]+),")
                set(_in_tagged TRUE)
                string(STRIP "${CMAKE_MATCH_1}" _raw_head)
                string(REGEX REPLACE "[^A-Za-z0-9_]" "_" _tag_head "${_raw_head}")
                set(_tag_idx 0)
            elseif(_in_tagged)
                if("${_line}" MATCHES "^${_TB_BS})")
                    set(_in_tagged FALSE)
                else()
                    string(REGEX MATCHALL "${_TB_BS}{[ ${_TB_TAB}]*${_TB_DQ}([^${_TB_DQ}]*)${_TB_DQ}" _titems "${_line}")
                    foreach(_item IN LISTS _titems)
                        string(REGEX REPLACE "^${_TB_BS}{[ ${_TB_TAB}]*${_TB_DQ}([^${_TB_DQ}]*)${_TB_DQ}$" "${_TB_BS}1" _raw_tag "${_item}")
                        string(REGEX REPLACE "[^A-Za-z0-9_]" "_" _clean_tag "${_raw_tag}")
                        set(_tname "${_tag_head}_${_clean_tag}")
                        if(_tag_idx GREATER_EQUAL 31)
                            set(_ll "LL")
                        else()
                            set(_ll "")
                        endif()
                        string(LENGTH "${_tname}" _nlen)
                        math(EXPR _p1 "32 - ${_nlen}")
                        if(_p1 LESS 1)
                            set(_p1 1)
                        endif()
                        math(EXPR _p2 "31 - ${_nlen}")
                        if(_p2 LESS 1)
                            set(_p2 1)
                        endif()
                        string(SUBSTRING "${_spaces}" 0 ${_p1} _sp1)
                        string(SUBSTRING "${_spaces}" 0 ${_p2} _sp2)
                        list(APPEND _tag_lines "#define ${_tname}${_sp1}${_tag_idx}")
                        list(APPEND _tag_lines "#define _${_tname}${_sp2}(1${_ll}<<${_tag_idx})")
                        math(EXPR _tag_idx "${_tag_idx} + 1")
                    endforeach()
                endif()
            endif()
        endforeach()
    endforeach()

    if(NOT _union_members)
        list(APPEND _union_members "${_TB_TAB}int _dummy${_TB_STX}")
    endif()

    set(_g_out_lines ${_struct_blocks} "extern union global_union {" ${_union_members} "} this${_TB_STX}")
    string(JOIN "${_TB_NL}" _globals_text ${_g_out_lines})
    string(REPLACE "${_TB_ETX}" "" _globals_text "${_globals_text}")
    string(REPLACE "${_TB_ENQ}" "${_TB_RBRACK}" _globals_text "${_globals_text}")
    string(REPLACE "${_TB_EOT}" "${_TB_LBRACK}" _globals_text "${_globals_text}")
    string(REPLACE "${_TB_STX}" ";" _globals_text "${_globals_text}")
    string(APPEND _globals_text "${_TB_NL}")

    if(_tag_lines)
        string(JOIN "${_TB_NL}" _tags_text ${_tag_lines})
        string(APPEND _tags_text "${_TB_NL}")
    else()
        set(_tags_text "")
    endif()

    set(${OUT_GLOBALS_VAR} "${_globals_text}" PARENT_SCOPE)
    set(${OUT_TAGS_VAR} "${_tags_text}" PARENT_SCOPE)
endfunction()

# -----------------------------------------------------------------------------
# Internal Helper: Extract Kconfig help entries from a file and append to list
# -----------------------------------------------------------------------------
function(_tb_extract_kconfig_help FILE_PATH IN_SEEN_SYMS OUT_SEEN_SYMS_VAR OUT_HELP_LINES_VAR)
    set(_seen ${IN_SEEN_SYMS})
    set(_h_out "")

    file(READ "${FILE_PATH}" _raw_check)
    string(FIND "${_raw_check}" "help" _h_pos)
    if(_h_pos EQUAL -1)
        set(${OUT_SEEN_SYMS_VAR} "${_seen}" PARENT_SCOPE)
        set(${OUT_HELP_LINES_VAR} "" PARENT_SCOPE)
        return()
    endif()

    _tb_read_lines("${FILE_PATH}" _lines)
    set(_current_sym "")
    set(_in_help FALSE)
    set(_help_indent 0)
    set(_help_buf "")

    set(_keywords "mainmenu;menu;choice;comment;config;endmenu;endchoice")

    foreach(_enc_line IN LISTS _lines)
        set(_raw_line "${_enc_line}")
        _tb_unescape_line(_raw_line)
        string(REGEX REPLACE "[ ${_TB_TAB}]+$" "" _line "${_raw_line}")

        set(_consume_as_keyword TRUE)
        if(_in_help)
            if("${_line}" STREQUAL "*/")
                set(_in_help FALSE)
                if(_help_buf)
                    string(JOIN "${_TB_NL}" _joined ${_help_buf})
                    string(REPLACE "${_TB_SOH}" "" _joined "${_joined}")
                    string(REGEX REPLACE "[ ${_TB_TAB}${_TB_NL}]+$" "" _joined "${_joined}")
                    string(TOLOWER "${_current_sym}" _low_sym)
                    list(FIND _seen "${_low_sym}" _sidx)
                    if(_sidx EQUAL -1)
                        list(APPEND _seen "${_low_sym}")
                        string(REPLACE "${_TB_BS}" "${_TB_BS}${_TB_BS}" _esc "${_joined}")
                        string(REPLACE "${_TB_DQ}" "${_TB_BS}${_TB_DQ}" _esc "${_esc}")
                        string(REPLACE "${_TB_NL}" "${_TB_BS}n" _esc "${_esc}")
                        list(APPEND _h_out "#define HELP_${_low_sym} ${_TB_DQ}${_esc}${_TB_DQ}" "${_TB_ETX}")
                    endif()
                endif()
                set(_help_buf "")
                set(_current_sym "")
                set(_consume_as_keyword FALSE)
            else()
                set(_indent 0)
                set(_idx 0)
                string(LENGTH "${_line}" _llen)
                while(_idx LESS _llen)
                    string(SUBSTRING "${_line}" ${_idx} 1 _c)
                    if("${_c}" STREQUAL " " OR "${_c}" STREQUAL "${_TB_TAB}")
                        if("${_c}" STREQUAL "${_TB_TAB}")
                            math(EXPR _indent "${_indent} | 7")
                        endif()
                        math(EXPR _indent "${_indent} + 1")
                        if(_help_buf AND _help_indent LESS _indent)
                            break()
                        endif()
                        math(EXPR _idx "${_idx} + 1")
                    else()
                        break()
                    endif()
                endwhile()

                string(SUBSTRING "${_line}" ${_idx} -1 _stripped)
                if(NOT _help_buf)
                    if("${_stripped}" STREQUAL "")
                        set(_consume_as_keyword FALSE)
                    else()
                        set(_help_indent ${_indent})
                    endif()
                endif()

                if(_consume_as_keyword)
                    if(_indent LESS _help_indent AND NOT "${_stripped}" STREQUAL "")
                        set(_in_help FALSE)
                        string(JOIN "${_TB_NL}" _joined ${_help_buf})
                        string(REPLACE "${_TB_SOH}" "" _joined "${_joined}")
                        string(REGEX REPLACE "[ ${_TB_TAB}${_TB_NL}]+$" "" _joined "${_joined}")
                        string(TOLOWER "${_current_sym}" _low_sym)
                        list(FIND _seen "${_low_sym}" _sidx)
                        if(_sidx EQUAL -1)
                            list(APPEND _seen "${_low_sym}")
                            string(REPLACE "${_TB_BS}" "${_TB_BS}${_TB_BS}" _esc "${_joined}")
                            string(REPLACE "${_TB_DQ}" "${_TB_BS}${_TB_DQ}" _esc "${_esc}")
                            string(REPLACE "${_TB_NL}" "${_TB_BS}n" _esc "${_esc}")
                            list(APPEND _h_out "#define HELP_${_low_sym} ${_TB_DQ}${_esc}${_TB_DQ}" "${_TB_ETX}")
                        endif()
                        set(_help_buf "")
                    else()
                        if("${_stripped}" STREQUAL "")
                            list(APPEND _help_buf "${_TB_SOH}")
                        else()
                            string(REPLACE ";" "${_TB_STX}" _safe_strip "${_stripped}")
                            string(REPLACE "${_TB_LBRACK}" "${_TB_EOT}" _safe_strip "${_safe_strip}")
                            string(REPLACE "${_TB_RBRACK}" "${_TB_ENQ}" _safe_strip "${_safe_strip}")
                            list(APPEND _help_buf "${_safe_strip}")
                        endif()
                        set(_consume_as_keyword FALSE)
                    endif()
                endif()
            endif()
        endif()

        if(_consume_as_keyword)
            string(REGEX REPLACE "^[ ${_TB_TAB}]+" "" _lstripped "${_line}")
            if(NOT "${_lstripped}" STREQUAL "" AND NOT "${_lstripped}" MATCHES "^#")
                string(REGEX MATCH "^([^ ${_TB_TAB}]+)(.*)$" _kw_m "${_lstripped}")
                set(_kw "${CMAKE_MATCH_1}")
                string(STRIP "${CMAKE_MATCH_2}" _arg)

                if("${_kw}" STREQUAL "config" AND NOT "${_arg}" STREQUAL "")
                    string(REGEX REPLACE "[ ${_TB_TAB}].*$" "" _current_sym "${_arg}")
                elseif("${_kw}" STREQUAL "help" AND "${_arg}" STREQUAL "" AND NOT "${_current_sym}" STREQUAL "")
                    set(_in_help TRUE)
                    set(_help_indent 0)
                    set(_help_buf "")
                else()
                    list(FIND _keywords "${_kw}" _kidx)
                    if(NOT _kidx EQUAL -1)
                        set(_current_sym "")
                    endif()
                endif()
            endif()
        endif()
    endforeach()

    if(_in_help AND NOT "${_current_sym}" STREQUAL "" AND _help_buf)
        string(JOIN "${_TB_NL}" _joined ${_help_buf})
        string(REPLACE "${_TB_SOH}" "" _joined "${_joined}")
        string(REGEX REPLACE "[ ${_TB_TAB}${_TB_NL}]+$" "" _joined "${_joined}")
        string(TOLOWER "${_current_sym}" _low_sym)
        list(FIND _seen "${_low_sym}" _sidx)
        if(_sidx EQUAL -1)
            list(APPEND _seen "${_low_sym}")
            string(REPLACE "${_TB_BS}" "${_TB_BS}${_TB_BS}" _esc "${_joined}")
            string(REPLACE "${_TB_DQ}" "${_TB_BS}${_TB_DQ}" _esc "${_esc}")
            string(REPLACE "${_TB_NL}" "${_TB_BS}n" _esc "${_esc}")
            list(APPEND _h_out "#define HELP_${_low_sym} ${_TB_DQ}${_esc}${_TB_DQ}" "${_TB_ETX}")
        endif()
    endif()

    set(${OUT_SEEN_SYMS_VAR} "${_seen}" PARENT_SCOPE)
    set(${OUT_HELP_LINES_VAR} "${_h_out}" PARENT_SCOPE)
endfunction()

# -----------------------------------------------------------------------------
# Internal Helper: Generate generated/help.h
# -----------------------------------------------------------------------------
function(_tb_generate_help_h TOYBOX_DIR OUT_HELP_VAR)
    set(_seen "")
    set(_all_help_lines "")

    if(EXISTS "${TOYBOX_DIR}/Config.in")
        _tb_extract_kconfig_help("${TOYBOX_DIR}/Config.in" "${_seen}" _seen _chunk)
        list(APPEND _all_help_lines ${_chunk})
    endif()

    _tb_get_toy_source_files("${TOYBOX_DIR}" _toy_files)
    foreach(_c_file IN LISTS _toy_files)
        _tb_extract_kconfig_help("${_c_file}" "${_seen}" _seen _chunk)
        list(APPEND _all_help_lines ${_chunk})
    endforeach()

    if(_all_help_lines)
        string(JOIN "${_TB_NL}" _help_text ${_all_help_lines})
        string(REPLACE "${_TB_ETX}" "" _help_text "${_help_text}")
        string(REPLACE "${_TB_ENQ}" "${_TB_RBRACK}" _help_text "${_help_text}")
        string(REPLACE "${_TB_EOT}" "${_TB_LBRACK}" _help_text "${_help_text}")
        string(REPLACE "${_TB_STX}" ";" _help_text "${_help_text}")
    else()
        set(_help_text "")
    endif()
    set(${OUT_HELP_VAR} "${_help_text}" PARENT_SCOPE)
endfunction()

# -----------------------------------------------------------------------------
# toybox_generate_build_files(
#   TOYBOX_DIR <dir>
#   OUT_DIR <dir>
#   [TARGET_DOS]
#   [OUT_SOURCES_VAR <var>]
# )
# -----------------------------------------------------------------------------
function(toybox_generate_build_files)
    set(_options TARGET_DOS)
    set(_one_value_args TOYBOX_DIR OUT_DIR PYTHON_EXECUTABLE OUT_SOURCES_VAR)
    set(_multi_value_args "")
    cmake_parse_arguments(ARG "${_options}" "${_one_value_args}" "${_multi_value_args}" ${ARGN})

    if(NOT ARG_TOYBOX_DIR)
        message(FATAL_ERROR "toybox_generate_build_files: TOYBOX_DIR is required")
    endif()
    if(NOT ARG_OUT_DIR)
        message(FATAL_ERROR "toybox_generate_build_files: OUT_DIR is required")
    endif()

    get_filename_component(_tb_abs "${ARG_TOYBOX_DIR}" ABSOLUTE)
    if(NOT EXISTS "${_tb_abs}/toys.h" OR NOT EXISTS "${_tb_abs}/main.c")
        message(FATAL_ERROR "Invalid toybox source directory (missing toys.h or main.c): ${_tb_abs}")
    endif()

    get_filename_component(_out_abs "${ARG_OUT_DIR}" ABSOLUTE)
    set(_gen_dir "${_out_abs}/generated")
    file(MAKE_DIRECTORY "${_gen_dir}")

    set(_enabled_symbols ${TOYBOX_COMMON_ENABLED_SYMBOLS})
    if(NOT ARG_TARGET_DOS)
        list(APPEND _enabled_symbols ${TOYBOX_WINDOWS_EXTRA_SYMBOLS})
    endif()

    _tb_collect_all_config_symbols("${_tb_abs}" _all_symbols)
    _tb_generate_config_h("${_all_symbols}" "${_enabled_symbols}" _config_h)
    _tb_process_toys("${_tb_abs}" "${_enabled_symbols}" _newtoys_h _flags_h _enabled_toys)
    _tb_generate_globals_and_tags("${_tb_abs}" _globals_h _tags_h)
    _tb_generate_help_h("${_tb_abs}" _help_h)

    file(WRITE "${_gen_dir}/config.h" "${_config_h}")
    file(WRITE "${_gen_dir}/newtoys.h" "${_newtoys_h}")
    file(WRITE "${_gen_dir}/flags.h" "${_flags_h}")
    file(WRITE "${_gen_dir}/globals.h" "${_globals_h}")
    file(WRITE "${_gen_dir}/tags.h" "${_tags_h}")
    file(WRITE "${_gen_dir}/help.h" "${_help_h}")

    set(_sys_dir "${_out_abs}/sys")
    file(MAKE_DIRECTORY "${_sys_dir}")
    set(_win_dos_cond "defined(_WIN32) || defined(_MSC_VER) || defined(__WATCOMC__) || defined(__DOS__) || defined(__MSDOS__)")
    set(_not_win_dos_cond "!defined(_WIN32) && !defined(_MSC_VER) && !defined(__WATCOMC__) && !defined(__DOS__) && !defined(__MSDOS__)")
    set(_bsd_apple_cond "defined(__APPLE__) || defined(__FreeBSD__) || defined(__OpenBSD__) || defined(__NetBSD__)")

    file(WRITE "${_sys_dir}/mount.h"
        "#ifndef TOYBOX_GEN_SYS_MOUNT_H${_TB_NL}"
        "#define TOYBOX_GEN_SYS_MOUNT_H${_TB_NL}"
        "#if ${_win_dos_cond}${_TB_NL}"
        "#include <sys/statfs.h>${_TB_NL}"
        "#include <sys/statvfs.h>${_TB_NL}"
        "#elif ${_bsd_apple_cond}${_TB_NL}"
        "#include_next <sys/mount.h>${_TB_NL}"
        "#endif${_TB_NL}"
        "#endif${_TB_NL}"
    )
    file(WRITE "${_sys_dir}/syscall.h"
        "#ifndef TOYBOX_GEN_SYS_SYSCALL_H${_TB_NL}"
        "#define TOYBOX_GEN_SYS_SYSCALL_H${_TB_NL}"
        "#if ${_not_win_dos_cond}${_TB_NL}"
        "#include_next <sys/syscall.h>${_TB_NL}"
        "#endif${_TB_NL}"
        "#endif${_TB_NL}"
    )
    file(WRITE "${_sys_dir}/ttydefaults.h"
        "#ifndef TOYBOX_GEN_SYS_TTYDEFAULTS_H${_TB_NL}"
        "#define TOYBOX_GEN_SYS_TTYDEFAULTS_H${_TB_NL}"
        "#ifndef CTRL${_TB_NL}"
        "#define CTRL(x) ((x)&037)${_TB_NL}"
        "#endif${_TB_NL}"
        "#endif${_TB_NL}"
    )

    set(_stub_headers
        "sys/swap.h"
        "sys/xattr.h"
        "sys/inotify.h"
        "pty.h"
        "utmpx.h"
        "shadow.h"
    )
    foreach(_stub_name IN LISTS _stub_headers)
        string(REGEX REPLACE "[^A-Za-z0-9_]" "_" _guard_sfx "${_stub_name}")
        string(TOUPPER "TOYBOX_GEN_${_guard_sfx}" _guard)
        file(WRITE "${_out_abs}/${_stub_name}"
            "#ifndef ${_guard}${_TB_NL}"
            "#define ${_guard}${_TB_NL}"
            "#if ${_not_win_dos_cond}${_TB_NL}"
            "#if defined(__has_include_next)${_TB_NL}"
            "#if __has_include_next(<${_stub_name}>)${_TB_NL}"
            "#include_next <${_stub_name}>${_TB_NL}"
            "#endif${_TB_NL}"
            "#endif${_TB_NL}"
            "#endif${_TB_NL}"
            "#endif${_TB_NL}"
        )
    endforeach()

    file(WRITE "${_out_abs}/sched.h"
        "#ifndef TOYBOX_GEN_SCHED_H${_TB_NL}"
        "#define TOYBOX_GEN_SCHED_H${_TB_NL}"
        "#if ${_win_dos_cond}${_TB_NL}"
        "#include ${_TB_DQ}posix-sched.h${_TB_DQ}${_TB_NL}"
        "#else${_TB_NL}"
        "#include_next <sched.h>${_TB_NL}"
        "#endif${_TB_NL}"
        "#endif${_TB_NL}"
    )

    set(_all_rel_sources "main.c")
    foreach(_lib_rel IN LISTS TOYBOX_CORE_LIB_SOURCES)
        if(EXISTS "${_tb_abs}/${_lib_rel}")
            list(APPEND _all_rel_sources "${_lib_rel}")
        endif()
    endforeach()
    list(APPEND _all_rel_sources ${_enabled_toys})

    set(_cmake_lines "set(TOYBOX_ENABLED_REL_SOURCES")
    foreach(_src IN LISTS _all_rel_sources)
        list(APPEND _cmake_lines "    ${_TB_DQ}${_src}${_TB_DQ}")
    endforeach()
    list(APPEND _cmake_lines ")")
    string(JOIN "${_TB_NL}" _cmake_text ${_cmake_lines})
    string(APPEND _cmake_text "${_TB_NL}")
    file(WRITE "${_out_abs}/enabled_sources.cmake" "${_cmake_text}")

    if(ARG_OUT_SOURCES_VAR)
        set(_abs_sources "")
        foreach(_rel IN LISTS _all_rel_sources)
            list(APPEND _abs_sources "${_tb_abs}/${_rel}")
        endforeach()
        set(${ARG_OUT_SOURCES_VAR} "${_abs_sources}" PARENT_SCOPE)
    endif()
endfunction()

# -----------------------------------------------------------------------------
# Script Mode Entry Point (cmake -D... -P cmake/GenerateToyboxHeaders.cmake)
# -----------------------------------------------------------------------------
if(CMAKE_SCRIPT_MODE_FILE AND CMAKE_SCRIPT_MODE_FILE STREQUAL CMAKE_CURRENT_LIST_FILE)
    if(NOT DEFINED TOYBOX_DIR OR "${TOYBOX_DIR}" STREQUAL "")
        message(FATAL_ERROR "Error: TOYBOX_DIR is required")
    endif()
    if((NOT DEFINED OUT_DIR OR "${OUT_DIR}" STREQUAL "") AND NOT FETCH_TOYBOX)
        message(FATAL_ERROR "Error: OUT_DIR is required unless FETCH_TOYBOX is specified")
    endif()

    if(FETCH_TOYBOX)
        set(_fetch_args DEST_DIR "${TOYBOX_DIR}")
        if(DEFINED TOYBOX_REV AND NOT "${TOYBOX_REV}" STREQUAL "")
            list(APPEND _fetch_args COMMIT "${TOYBOX_REV}")
        endif()
        if(DEFINED TOYBOX_REPO_URLS)
            list(APPEND _fetch_args REPO_URLS ${TOYBOX_REPO_URLS})
        endif()
        if(DEFINED TOYBOX_RETRIES_PER_URL)
            list(APPEND _fetch_args RETRIES_PER_URL "${TOYBOX_RETRIES_PER_URL}")
        endif()
        if(DEFINED TOYBOX_RETRY_DELAY_SEC)
            list(APPEND _fetch_args RETRY_DELAY_SEC "${TOYBOX_RETRY_DELAY_SEC}")
        endif()
        toybox_ensure_source(${_fetch_args})
    endif()

    if(DEFINED OUT_DIR AND NOT "${OUT_DIR}" STREQUAL "")
        set(_gen_args TOYBOX_DIR "${TOYBOX_DIR}" OUT_DIR "${OUT_DIR}")
        if(TARGET_DOS)
            list(APPEND _gen_args TARGET_DOS)
        endif()
        toybox_generate_build_files(${_gen_args})
    endif()
endif()
