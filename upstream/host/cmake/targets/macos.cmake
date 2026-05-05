# macos specific target definitions

if (SUNSHINE_BUILD_HOMEBREW)
    target_link_options(sunshine PRIVATE LINKER:-sectcreate,__TEXT,__info_plist,${APPLE_PLIST_FILE})
else()
    # .app build
    set_target_properties(sunshine PROPERTIES
            OUTPUT_NAME "${CMAKE_PROJECT_NAME}"
            MACOSX_BUNDLE_BUNDLE_NAME "${CMAKE_PROJECT_NAME}"
            MACOSX_BUNDLE_GUI_IDENTIFIER "${PROJECT_FQDN}"
            MACOSX_BUNDLE_INFO_PLIST "${APPLE_PLIST_FILE}"
            MACOSX_BUNDLE_ICON_FILE "sunshine.icns"
            MACOSX_BUNDLE_SHORT_VERSION_STRING "${PROJECT_VERSION}"
            MACOSX_BUNDLE_BUNDLE_VERSION "${PROJECT_VERSION}")

    # Populate bundle resources in the build tree for local runs.
    set(_bundle_resources_dir "$<TARGET_FILE_DIR:sunshine>/../Resources")
    add_custom_command(TARGET sunshine POST_BUILD
            COMMENT "Copying bundle resources to build tree"
            COMMAND "${CMAKE_COMMAND}" -E make_directory "${_bundle_resources_dir}"
            COMMAND "${CMAKE_COMMAND}" -E copy_directory "${CMAKE_BINARY_DIR}/assets" "${_bundle_resources_dir}/assets"
            VERBATIM)
endif()

# Tell linker to dynamically load these symbols at runtime, in case they're unavailable:
target_link_options(sunshine PRIVATE -Wl,-U,_CGPreflightScreenCaptureAccess -Wl,-U,_CGRequestScreenCaptureAccess)

# Phase 4: vd_helper subprocess for virtual extended display.
add_executable(vd_helper
        src/platform/macos/vd_helper.m
)
set_source_files_properties(
        src/platform/macos/vd_helper.m
        PROPERTIES COMPILE_FLAGS "-fobjc-arc"
)
target_link_libraries(vd_helper PRIVATE
        "-framework CoreGraphics"
        "-framework Foundation"
        "-framework AppKit"
)
target_link_options(vd_helper PRIVATE
        # Per-symbol weak resolution for SkyLight SLS* private functions
        # (matches the convention on line 26 above for sunshine's CGPreflight*).
        "-Wl,-U,_SLSBeginDisplayConfiguration"
        "-Wl,-U,_SLSConfigureDisplayEnabled"
        "-Wl,-U,_SLSConfigureDisplayOrigin"
        "-Wl,-U,_SLSCompleteDisplayConfiguration"
)
# Place vd_helper alongside Sunshine. CMake leaves the helper at build/
# by default; for local .app runs we copy it into Sunshine.app/Contents/MacOS/
# so MacVirtualDisplayManager::helper_path_() (which sibling-locates via
# _NSGetExecutablePath) finds it. The packaging step (cpack DragNDrop) will
# pick up the helper from the bundle dir.
set_target_properties(vd_helper PROPERTIES
        RUNTIME_OUTPUT_DIRECTORY "${CMAKE_RUNTIME_OUTPUT_DIRECTORY}"
)
add_dependencies(sunshine vd_helper)

if (NOT SUNSHINE_BUILD_HOMEBREW)
    add_custom_command(TARGET sunshine POST_BUILD
            COMMENT "Copying vd_helper into Sunshine.app/Contents/MacOS/"
            COMMAND "${CMAKE_COMMAND}" -E copy_if_different
                    "$<TARGET_FILE:vd_helper>"
                    "$<TARGET_FILE_DIR:sunshine>/vd_helper"
            VERBATIM)
endif()
