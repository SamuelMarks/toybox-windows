# =============================================================================
# CPackConfig.cmake - Binary Package Configuration for Toybox Windows & DOS
#
# Configures CPack to produce standalone portable ZIP archives, NSIS (.exe),
# and WiX (.msi) Windows installers containing the compiled toybox executable
# and licenses.
# =============================================================================

set(CPACK_PACKAGE_NAME "toybox")
set(CPACK_PACKAGE_VENDOR "Rob Landley")
set(CPACK_PACKAGE_VERSION "0.8.15")
set(CPACK_PACKAGE_VERSION_MAJOR "0")
set(CPACK_PACKAGE_VERSION_MINOR "8")
set(CPACK_PACKAGE_VERSION_PATCH "15")
set(CPACK_PACKAGE_DESCRIPTION_SUMMARY "Toybox all-in-one command-line utilities for native Windows (MSVC) and 32-bit DOS (OpenWatcom).")
set(CPACK_PACKAGE_HOMEPAGE_URL "https://landley.net/toybox/")
set(CPACK_PACKAGE_CONTACT "Samuel Marks")
set(CPACK_PACKAGE_INSTALL_DIRECTORY "toybox")
set(CPACK_GENERATOR "ZIP;NSIS;WIX")

set(_cpack_license_src "")
if(DEFINED TOYBOX_SOURCE_DIR AND EXISTS "${TOYBOX_SOURCE_DIR}/LICENSE")
    set(_cpack_license_src "${TOYBOX_SOURCE_DIR}/LICENSE")
elseif(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/LICENSE-MIT")
    set(_cpack_license_src "${CMAKE_CURRENT_SOURCE_DIR}/LICENSE-MIT")
endif()

if(_cpack_license_src)
    if(DEFINED CMAKE_CURRENT_BINARY_DIR AND NOT "${CMAKE_CURRENT_BINARY_DIR}" STREQUAL "${CMAKE_CURRENT_SOURCE_DIR}")
        configure_file("${_cpack_license_src}" "${CMAKE_CURRENT_BINARY_DIR}/LICENSE.txt" COPYONLY)
        set(CPACK_RESOURCE_FILE_LICENSE "${CMAKE_CURRENT_BINARY_DIR}/LICENSE.txt")
    else()
        set(CPACK_RESOURCE_FILE_LICENSE "${_cpack_license_src}")
    endif()
endif()

set(CPACK_NSIS_DISPLAY_NAME "Toybox for Windows")
set(CPACK_NSIS_PACKAGE_NAME "Toybox for Windows")
set(CPACK_NSIS_MODIFY_PATH ON)

set(CPACK_WIX_UPGRADE_GUID "7A9E4C12-5B8D-4E3A-9C61-3D2F8B4A1095")
