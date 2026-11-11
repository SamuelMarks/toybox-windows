# =============================================================================
# CPackSourceConfig.cmake - Source Archive Configuration for Toybox Windows
# =============================================================================

set(CPACK_SOURCE_GENERATOR "ZIP;TGZ")
set(CPACK_SOURCE_PACKAGE_FILE_NAME "toybox-0.8.15-src")
set(CPACK_SOURCE_IGNORE_FILES
    "/\.git/"
    "/build.*/"
    "/\.vscode/"
    "/\.idea/"
    "/__pycache__/"
    "/\.DS_Store"
)
