# =============================================================================
# CMakeLists.txt - Toybox Native Windows (MSVC) & OpenWatcom 32-bit DOS Build
#
# Orchestrates locating or fetching upstream Toybox (0.8.15), deterministic
# build-time header and configuration generation (generated/config.h,
# generated/newtoys.h, generated/flags.h, generated/globals.h,
# generated/tags.h, generated/help.h), C99/GNU-to-C89/MSVC/Watcom AST source
# transformation via auto-win-msvc, POSIX/BSD/Linux polyfill linking, CPack
# installer packaging (ZIP, NSIS, WiX), and CTest functional verification.
#
# Parameters / Cache Variables:
#   TOYBOX_SOURCE_DIR - Path to upstream Toybox source tree (auto-detected at
#                       ../toybox or ./toybox, or shallow-fetched via Git).
#   TOYBOX_GIT_TAG    - Git revision/tag to fetch if TOYBOX_SOURCE_DIR is not
#                       present locally (default: 0.8.15).
#   BUILD_TESTING     - Enable CTest functional verification suite (default: ON).
# =============================================================================

cmake_minimum_required(VERSION 3.15)
if(POLICY CMP0135)
    cmake_policy(SET CMP0135 NEW)
endif()
if(POLICY CMP0091)
    cmake_policy(SET CMP0091 NEW)
    set(CMAKE_POLICY_DEFAULT_CMP0091 NEW)
endif()
if(POLICY CMP0141)
    cmake_policy(SET CMP0141 NEW)
    set(CMAKE_POLICY_DEFAULT_CMP0141 NEW)
endif()

project(toybox-windows VERSION 0.8.15 LANGUAGES C)

include(CTest)
include(FetchContent)
find_package(Python3 REQUIRED COMPONENTS Interpreter)

# -----------------------------------------------------------------------------
# 1. Locate or Fetch auto-win-msvc Compatibility Layer
# -----------------------------------------------------------------------------
set(BUILD_SHARED_LIBS OFF CACHE BOOL "Build static libraries" FORCE)
set(AUTO_WIN_MSVC_BUILD_TESTS OFF CACHE BOOL "Disable auto-win-msvc internal tests" FORCE)

if(CMAKE_SYSTEM_NAME STREQUAL "DOS" OR WATCOM OR CMAKE_C_COMPILER_ID MATCHES "Watcom")
    set(TOYBOX_TARGET_DOS TRUE)
    set(AUTO_WIN_MSVC_SINGLE_THREADED ON CACHE BOOL "Enable single-threaded mode for DOS" FORCE)
else()
    set(TOYBOX_TARGET_DOS FALSE)
endif()

if(DEFINED FETCHCONTENT_SOURCE_DIR_AUTO_WIN_MSVC AND EXISTS "${FETCHCONTENT_SOURCE_DIR_AUTO_WIN_MSVC}/CMakeLists.txt")
    get_filename_component(AUTO_WIN_MSVC_DIR "${FETCHCONTENT_SOURCE_DIR_AUTO_WIN_MSVC}" ABSOLUTE)
elseif(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/../auto-win-msvc/CMakeLists.txt")
    get_filename_component(AUTO_WIN_MSVC_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../auto-win-msvc" ABSOLUTE)
elseif(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/auto-win-msvc/CMakeLists.txt")
    get_filename_component(AUTO_WIN_MSVC_DIR "${CMAKE_CURRENT_SOURCE_DIR}/auto-win-msvc" ABSOLUTE)
endif()

if(DEFINED AUTO_WIN_MSVC_DIR)
    message(STATUS "Using local auto-win-msvc at ${AUTO_WIN_MSVC_DIR}")
    set(FETCHCONTENT_SOURCE_DIR_AUTO_WIN_MSVC "${AUTO_WIN_MSVC_DIR}" CACHE PATH "" FORCE)
endif()

if(WIN32 OR MSVC OR MINGW OR TOYBOX_TARGET_DOS OR NOT DEFINED AUTO_WIN_MSVC_DIR)
    set(_saved_build_testing "${BUILD_TESTING}")
    set(BUILD_TESTING OFF CACHE BOOL "" FORCE)
    FetchContent_Declare(
        auto_win_msvc
        GIT_REPOSITORY https://github.com/SamuelMarks/auto-win-msvc.git
        GIT_TAG        main
    )
    FetchContent_MakeAvailable(auto_win_msvc)
    set(BUILD_TESTING "${_saved_build_testing}" CACHE BOOL "" FORCE)
endif()

# -----------------------------------------------------------------------------
# 2. Locate or Fetch Upstream Toybox Source Tree (Zero Direct Source Edits)
# -----------------------------------------------------------------------------
include("${CMAKE_CURRENT_SOURCE_DIR}/cmake/GenerateToyboxHeaders.cmake")

set(TOYBOX_GIT_TAG "${TOYBOX_DEFAULT_REV}" CACHE STRING "Upstream toybox commit or tag")

if(DEFINED TOYBOX_SOURCE_DIR AND EXISTS "${TOYBOX_SOURCE_DIR}/toys.h")
    get_filename_component(TOYBOX_SOURCE_DIR "${TOYBOX_SOURCE_DIR}" ABSOLUTE)
elseif(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/../toybox/toys.h")
    get_filename_component(TOYBOX_SOURCE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../toybox" ABSOLUTE)
elseif(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/toybox/toys.h")
    get_filename_component(TOYBOX_SOURCE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/toybox" ABSOLUTE)
else()
    set(_toybox_fetch_dir "${CMAKE_CURRENT_BINARY_DIR}/toybox_upstream")
    message(STATUS "Fetching upstream toybox (${TOYBOX_GIT_TAG}) into ${_toybox_fetch_dir}...")
    toybox_ensure_source(
        DEST_DIR "${_toybox_fetch_dir}"
        COMMIT "${TOYBOX_GIT_TAG}"
    )
    get_filename_component(TOYBOX_SOURCE_DIR "${_toybox_fetch_dir}" ABSOLUTE)
endif()

message(STATUS "Using Toybox source directory: ${TOYBOX_SOURCE_DIR}")

# -----------------------------------------------------------------------------
# 3. Deterministic Build-Time Header & Source List Generation
# -----------------------------------------------------------------------------
set(TOYBOX_GENERATED_DIR "${CMAKE_CURRENT_BINARY_DIR}/toybox_generated")

set(_gen_args
    TOYBOX_DIR "${TOYBOX_SOURCE_DIR}"
    OUT_DIR "${TOYBOX_GENERATED_DIR}"
    PYTHON_EXECUTABLE "${Python3_EXECUTABLE}"
    OUT_SOURCES_VAR TOYBOX_RAW_SOURCES
)
if(TOYBOX_TARGET_DOS)
    list(APPEND _gen_args TARGET_DOS)
endif()

toybox_generate_build_files(${_gen_args})

# -----------------------------------------------------------------------------
# 4. Source Transformation (C99/GNU -> C89/MSVC/OpenWatcom via auto-win-msvc)
# -----------------------------------------------------------------------------
if(EXISTS "${auto_win_msvc_SOURCE_DIR}/cmake/AutoWinMsvcTransform.cmake")
    include("${auto_win_msvc_SOURCE_DIR}/cmake/AutoWinMsvcTransform.cmake")
elseif(DEFINED AUTO_WIN_MSVC_DIR AND EXISTS "${AUTO_WIN_MSVC_DIR}/cmake/AutoWinMsvcTransform.cmake")
    include("${AUTO_WIN_MSVC_DIR}/cmake/AutoWinMsvcTransform.cmake")
endif()

if(COMMAND auto_win_msvc_transform_sources)
    auto_win_msvc_transform_sources(
        OUTPUT_DIR "${CMAKE_CURRENT_BINARY_DIR}/src_gen"
        SOURCES ${TOYBOX_RAW_SOURCES}
        OUTPUT_VAR TOYBOX_SOURCES
    )
else()
    set(TOYBOX_SOURCES ${TOYBOX_RAW_SOURCES})
endif()

# -----------------------------------------------------------------------------
# 5. Executable Target, Include Directories, and Platform Flags
# -----------------------------------------------------------------------------
add_executable(toybox ${TOYBOX_SOURCES})

target_include_directories(toybox PRIVATE
    "${TOYBOX_GENERATED_DIR}"
    "${CMAKE_CURRENT_BINARY_DIR}/src_gen"
    "${TOYBOX_SOURCE_DIR}"
)

if(WIN32 OR MSVC OR MINGW OR TOYBOX_TARGET_DOS)
    target_link_libraries(toybox PRIVATE auto-win-msvc)
endif()

set(_awm_configure_h "${auto_win_msvc_SOURCE_DIR}/include/auto-win-msvc-configure.h")
if(NOT EXISTS "${_awm_configure_h}" AND DEFINED AUTO_WIN_MSVC_DIR)
    set(_awm_configure_h "${AUTO_WIN_MSVC_DIR}/include/auto-win-msvc-configure.h")
endif()

if(MSVC)
    target_compile_definitions(toybox PRIVATE
        _CRT_SECURE_NO_WARNINGS
        _CRT_NONSTDC_NO_DEPRECATE
        _WINSOCK_DEPRECATED_NO_WARNINGS
        WIN32_LEAN_AND_MEAN
    )
    target_compile_options(toybox PRIVATE
        /utf-8
        /std:c11
        /wd4018 /wd4090 /wd4101 /wd4113 /wd4146 /wd4244 /wd4267 /wd4311 /wd4312 /wd4996
    )
    if(EXISTS "${_awm_configure_h}")
        target_compile_options(toybox PRIVATE "/FI${_awm_configure_h}")
    endif()
    target_link_libraries(toybox PRIVATE
        ws2_32
        advapi32
        userenv
        psapi
        iphlpapi
        shlwapi
        bcrypt
    )
elseif(WATCOM OR CMAKE_C_COMPILER_ID MATCHES "Watcom")
    if(EXISTS "${_awm_configure_h}")
        target_compile_options(toybox PRIVATE "-fi=${_awm_configure_h}")
    endif()
    target_compile_options(toybox PRIVATE -za99 -wcd=107 -wcd=1178 -wcd=1179 -wcd=124 -wcd=136 -wcd=201 -wcd=202)
elseif(MINGW)
    if(EXISTS "${_awm_configure_h}")
        target_compile_options(toybox PRIVATE "-include" "${_awm_configure_h}")
    endif()
    target_compile_options(toybox PRIVATE -std=gnu11 -w -funsigned-char)
    target_link_libraries(toybox PRIVATE
        ws2_32
        advapi32
        userenv
        psapi
        iphlpapi
        shlwapi
        bcrypt
    )
else()
    target_compile_options(toybox PRIVATE
        -std=gnu11
        -funsigned-char
        -Wno-deprecated-declarations
        -Wno-string-plus-int
        -Wno-char-subscripts
        -Wno-unused-result
    )
    find_library(MATH_LIBRARY m)
    if(MATH_LIBRARY)
        target_link_libraries(toybox PRIVATE "${MATH_LIBRARY}")
    endif()
    find_library(CRYPT_LIBRARY crypt)
    if(CRYPT_LIBRARY)
        target_link_libraries(toybox PRIVATE "${CRYPT_LIBRARY}")
    endif()
endif()

# -----------------------------------------------------------------------------
# 6. OpenWatcom DOS Extender Staging (dos32a.exe / dos4gw.exe)
# -----------------------------------------------------------------------------
if(TOYBOX_TARGET_DOS)
    set(_watcom_env "$ENV{WATCOM}")
    if(_watcom_env)
        file(TO_CMAKE_PATH "${_watcom_env}" _watcom_root)
        foreach(_extender dos32a.exe dos4gw.exe)
            if(EXISTS "${_watcom_root}/binw/${_extender}")
                file(COPY "${_watcom_root}/binw/${_extender}"
                     DESTINATION "${CMAKE_CURRENT_BINARY_DIR}")
            endif()
        endforeach()
    endif()
endif()

# -----------------------------------------------------------------------------
# 7. Installation & CPack Configuration
# -----------------------------------------------------------------------------
install(TARGETS toybox RUNTIME DESTINATION bin)
include("${CMAKE_CURRENT_SOURCE_DIR}/CPackConfig.cmake")
include(CPack)

# -----------------------------------------------------------------------------
# 8. CTest Functional Verification Suite
# -----------------------------------------------------------------------------
if(BUILD_TESTING)
    string(ASCII 92 _TB_BS)
    add_test(NAME toybox_version COMMAND toybox --version)
    set_tests_properties(toybox_version PROPERTIES PASS_REGULAR_EXPRESSION "toybox 0${_TB_BS}.8${_TB_BS}.15")

    add_test(NAME toybox_list COMMAND toybox)
    set_tests_properties(toybox_list PROPERTIES PASS_REGULAR_EXPRESSION "echo.*grep.*sed.*tar")

    add_test(NAME toybox_help_echo COMMAND toybox help echo)
    set_tests_properties(toybox_help_echo PROPERTIES PASS_REGULAR_EXPRESSION "usage: echo")

    add_test(NAME toybox_echo COMMAND toybox echo "hello toybox-windows")
    set_tests_properties(toybox_echo PROPERTIES PASS_REGULAR_EXPRESSION "hello toybox-windows")

    add_test(NAME toybox_printf COMMAND toybox printf "%s-%04d" "item" 42)
    set_tests_properties(toybox_printf PROPERTIES PASS_REGULAR_EXPRESSION "item-0042")

    add_test(NAME toybox_true COMMAND toybox true)

    add_test(NAME toybox_test_expr COMMAND toybox test 42 -eq 42)

    add_test(NAME toybox_expr_math COMMAND toybox expr 6 + 7)
    set_tests_properties(toybox_expr_math PROPERTIES PASS_REGULAR_EXPRESSION "^13")

    add_test(NAME toybox_seq COMMAND toybox seq 1 3)
    set_tests_properties(toybox_seq PROPERTIES PASS_REGULAR_EXPRESSION "1.*2.*3")

    add_test(NAME toybox_basename COMMAND toybox basename /usr/local/bin/toybox.exe .exe)
    set_tests_properties(toybox_basename PROPERTIES PASS_REGULAR_EXPRESSION "^toybox")

    add_test(NAME toybox_dirname COMMAND toybox dirname /usr/local/bin/toybox)
    set_tests_properties(toybox_dirname PROPERTIES PASS_REGULAR_EXPRESSION "^/usr/local/bin")

    add_test(NAME toybox_factor COMMAND toybox factor 42)
    set_tests_properties(toybox_factor PROPERTIES PASS_REGULAR_EXPRESSION "42: 2 3 7")

    add_test(NAME toybox_uname COMMAND toybox uname)

    add_test(NAME toybox_whoami COMMAND toybox whoami)

    add_test(NAME toybox_pwd COMMAND toybox pwd)

    add_test(NAME toybox_uuidgen COMMAND toybox uuidgen)
    set_tests_properties(toybox_uuidgen PROPERTIES PASS_REGULAR_EXPRESSION "[0-9a-fA-F-]+")

    add_test(NAME toybox_awk COMMAND toybox awk "BEGIN { print 21 * 2 }")
    set_tests_properties(toybox_awk PROPERTIES PASS_REGULAR_EXPRESSION "^42")

    add_test(
        NAME toybox_pipeline_suite
        COMMAND "${Python3_EXECUTABLE}" "${CMAKE_CURRENT_SOURCE_DIR}/scripts/run_toybox_tests.py"
                --toybox "$<TARGET_FILE:toybox>"
    )
endif()
