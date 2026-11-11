# =============================================================================
# cmake/GenerateToyboxHeaders.cmake - CMake Build-Time Header & Source Codegen
#
# Provides pure CMake / Python orchestration for:
#   1. Fetching upstream Toybox (with shallow HTTPS fetch and multi-mirror
#      fallback) when ../toybox is not already checked out locally.
#   2. Parsing TOYBOX_VERSION from upstream toys.h.
#   3. Invoking scripts/generate_toybox_headers.py to deterministically emit
#      generated/config.h, generated/newtoys.h, generated/flags.h,
#      generated/globals.h, generated/tags.h, generated/help.h, and
#      enabled_sources.cmake.
# =============================================================================

set(TOYBOX_DEFAULT_REV "0.8.15")
set(TOYBOX_DEFAULT_REPOS
    "https://github.com/landley/toybox.git"
    "https://codeberg.org/landley/toybox.git"
)

string(ASCII 92 _TB_BS)
string(ASCII 34 _TB_DQ)
string(ASCII 10 _TB_NL)

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
    string(REGEX MATCH "#define[ 	]+TOYBOX_VERSION[ 	]+${_TB_DQ}([^${_TB_DQ}]+)${_TB_DQ}" _match "${TOYS_H_TEXT}")
    if(_match)
        string(STRIP "${CMAKE_MATCH_1}" _version)
    endif()
    set(${OUT_VERSION} "${_version}" PARENT_SCOPE)
endfunction()

# -----------------------------------------------------------------------------
# toybox_generate_build_files(
#   TOYBOX_DIR <dir>
#   OUT_DIR <dir>
#   [PYTHON_EXECUTABLE <exe>]
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
    if(NOT EXISTS "${_tb_abs}/toys.h")
        message(FATAL_ERROR "toys.h not found in ${_tb_abs}")
    endif()

    if(NOT ARG_PYTHON_EXECUTABLE)
        if(DEFINED Python3_EXECUTABLE AND NOT "${Python3_EXECUTABLE}" STREQUAL "")
            set(ARG_PYTHON_EXECUTABLE "${Python3_EXECUTABLE}")
        else()
            find_package(Python3 REQUIRED COMPONENTS Interpreter)
            set(ARG_PYTHON_EXECUTABLE "${Python3_EXECUTABLE}")
        endif()
    endif()

    get_filename_component(_cmake_dir "${CMAKE_CURRENT_FUNCTION_LIST_DIR}" ABSOLUTE)
    get_filename_component(_repo_root "${_cmake_dir}/.." ABSOLUTE)
    set(_py_script "${_repo_root}/scripts/generate_toybox_headers.py")

    set(_cmd_args
        "${ARG_PYTHON_EXECUTABLE}"
        "${_py_script}"
        "--toybox-dir" "${_tb_abs}"
        "--out-dir" "${ARG_OUT_DIR}"
    )
    if(ARG_TARGET_DOS)
        list(APPEND _cmd_args "--dos")
    endif()

    execute_process(
        COMMAND ${_cmd_args}
        RESULT_VARIABLE _gen_rc
        OUTPUT_VARIABLE _gen_out
        ERROR_VARIABLE _gen_err
        OUTPUT_STRIP_TRAILING_WHITESPACE
        ERROR_STRIP_TRAILING_WHITESPACE
    )
    if(NOT _gen_rc EQUAL 0)
        message(FATAL_ERROR "generate_toybox_headers.py failed (${_gen_rc}): ${_gen_err}")
    endif()

    include("${ARG_OUT_DIR}/enabled_sources.cmake")
    if(ARG_OUT_SOURCES_VAR)
        set(_abs_sources "")
        foreach(_rel IN LISTS TOYBOX_ENABLED_REL_SOURCES)
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
