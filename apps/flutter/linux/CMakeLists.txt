# Project-level configuration.
cmake_minimum_required(VERSION 3.13)
project(runner LANGUAGES CXX)

# The name of the executable created for the application. Change this to change
# the on-disk name of your application.
set(BINARY_NAME "xdremux")
# The unique GTK application identifier for this application. See:
# https://wiki.gnome.org/HowDoI/ChooseApplicationID
set(APPLICATION_ID "io.github.beetman.xdremux")

# Explicitly opt in to modern CMake behaviors to avoid warnings with recent
# versions of CMake.
cmake_policy(SET CMP0063 NEW)

# Load bundled libraries from the lib/ directory relative to the binary.
set(CMAKE_INSTALL_RPATH "$ORIGIN/lib")

# Root filesystem for cross-building.
if(FLUTTER_TARGET_PLATFORM_SYSROOT)
  set(CMAKE_SYSROOT ${FLUTTER_TARGET_PLATFORM_SYSROOT})
  set(CMAKE_FIND_ROOT_PATH ${CMAKE_SYSROOT})
  set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
  set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
  set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
  set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
endif()

# Define build configuration options.
if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
  set(CMAKE_BUILD_TYPE "Debug" CACHE
    STRING "Flutter build mode" FORCE)
  set_property(CACHE CMAKE_BUILD_TYPE PROPERTY STRINGS
    "Debug" "Profile" "Release")
endif()

# Compilation settings that should be applied to most targets.
#
# Be cautious about adding new options here, as plugins use this function by
# default. In most cases, you should add new options to specific targets instead
# of modifying this function.
function(APPLY_STANDARD_SETTINGS TARGET)
  target_compile_features(${TARGET} PUBLIC cxx_std_14)
  target_compile_options(${TARGET} PRIVATE -Wall -Werror)
  target_compile_options(${TARGET} PRIVATE "$<$<NOT:$<CONFIG:Debug>>:-O3>")
  target_compile_definitions(${TARGET} PRIVATE "$<$<NOT:$<CONFIG:Debug>>:NDEBUG>")
endfunction()

# Flutter library and tool build rules.
set(FLUTTER_MANAGED_DIR "${CMAKE_CURRENT_SOURCE_DIR}/flutter")
add_subdirectory(${FLUTTER_MANAGED_DIR})

# System-level dependencies.
find_package(PkgConfig REQUIRED)
pkg_check_modules(GTK REQUIRED IMPORTED_TARGET gtk+-3.0)

# === Linux plugin filtering (runtime dependency convergence) ===
# The Flutter tool generates one plugin list for every platform declared in
# pubspec.yaml. Two native plugins are not part of the Linux product and would
# otherwise pull in avoidable runtime dependencies, so filter them out of
# build-directory copies of the generated files (same idea as the Windows jni
# filter in ../windows/CMakeLists.txt):
#   * tray_manager: the tray is Windows-only in Dart (TrayService is a no-op on
#     Linux); its Linux plugin links libayatana-appindicator3, which would
#     become a hard runtime dependency of the app binary.
#   * jni: an Android-only FFI helper (path_provider). It builds libdartjni.so,
#     whose NEEDED entry is libjvm.so — a JVM must not be required on Linux.
set(XDREMUX_GENERATED_PLUGINS_CMAKE
  "${CMAKE_CURRENT_SOURCE_DIR}/flutter/generated_plugins.cmake")
set(XDREMUX_GENERATED_PLUGIN_REGISTRANT
  "${CMAKE_CURRENT_SOURCE_DIR}/flutter/generated_plugin_registrant.cc")
set(XDREMUX_FILTERED_PLUGINS_CMAKE
  "${CMAKE_CURRENT_BINARY_DIR}/xdremux_linux_plugins.cmake")
set(XDREMUX_FILTERED_PLUGIN_REGISTRANT
  "${CMAKE_CURRENT_BINARY_DIR}/xdremux_linux_plugin_registrant.cc")

# Re-run CMake when Flutter rewrites the generated plugin files.
set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS
  "${XDREMUX_GENERATED_PLUGINS_CMAKE}"
  "${XDREMUX_GENERATED_PLUGIN_REGISTRANT}")

# Remove a plugin entry from the generated plugin list, preserving the rest.
function(xdremux_filter_plugin_list input output)
  file(READ "${input}" content)
  string(REPLACE "\r" "" content "${content}")
  string(REGEX REPLACE "\n[ \t]*(tray_manager|jni)[ \t]*\n" "\n"
    content "${content}")
  file(WRITE "${output}" "${content}")
endfunction()

# Remove every line that references a filtered plugin from the generated
# registrant. Each line of a registration block (include, registrar lookup and
# register call) mentions the package or class name, so line filtering is
# robust against small formatting changes.
function(xdremux_filter_plugin_registrant input output)
  file(READ "${input}" content)
  string(REGEX REPLACE "[^\n]*tray_manager[^\n]*\n" "" content "${content}")
  string(REGEX REPLACE "[^\n]*TrayManagerPlugin[^\n]*\n" "" content "${content}")
  file(WRITE "${output}" "${content}")
  # The filtered registrant includes this header; keep a copy next to it.
  get_filename_component(source_dir "${input}" DIRECTORY)
  get_filename_component(output_dir "${output}" DIRECTORY)
  configure_file("${source_dir}/generated_plugin_registrant.h"
    "${output_dir}/generated_plugin_registrant.h" COPYONLY)
endfunction()

xdremux_filter_plugin_list(
  "${XDREMUX_GENERATED_PLUGINS_CMAKE}" "${XDREMUX_FILTERED_PLUGINS_CMAKE}")
xdremux_filter_plugin_registrant(
  "${XDREMUX_GENERATED_PLUGIN_REGISTRANT}"
  "${XDREMUX_FILTERED_PLUGIN_REGISTRANT}")

# Application build; see runner/CMakeLists.txt.
add_subdirectory("runner")

# Run the Flutter tool portions of the build. This must not be removed.
add_dependencies(${BINARY_NAME} flutter_assemble)

# Only the install-generated bundle's copy of the executable will launch
# correctly, since the resources must in the right relative locations. To avoid
# people trying to run the unbundled copy, put it in a subdirectory instead of
# the default top-level location.
set_target_properties(${BINARY_NAME}
  PROPERTIES
  RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/intermediates_do_not_run"
)


# Generated plugin build rules, which manage building the plugins and adding
# them to the application. This is the filtered copy produced above, not the
# Flutter-generated file itself.
include("${XDREMUX_FILTERED_PLUGINS_CMAKE}")


# === Installation ===
# By default, "installing" just makes a relocatable bundle in the build
# directory.
set(BUILD_BUNDLE_DIR "${PROJECT_BINARY_DIR}/bundle")
if(CMAKE_INSTALL_PREFIX_INITIALIZED_TO_DEFAULT)
  set(CMAKE_INSTALL_PREFIX "${BUILD_BUNDLE_DIR}" CACHE PATH "..." FORCE)
endif()

# Start with a clean build bundle directory every time.
install(CODE "
  file(REMOVE_RECURSE \"${BUILD_BUNDLE_DIR}/\")
  " COMPONENT Runtime)

set(INSTALL_BUNDLE_DATA_DIR "${CMAKE_INSTALL_PREFIX}/data")
set(INSTALL_BUNDLE_LIB_DIR "${CMAKE_INSTALL_PREFIX}/lib")

install(TARGETS ${BINARY_NAME} RUNTIME DESTINATION "${CMAKE_INSTALL_PREFIX}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_ICU_DATA_FILE}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
  COMPONENT Runtime)

# Window icon, installed next to the Flutter assets and picked up by the runner
# from <executable dir>/data/app_icon.png.
install(FILES "${CMAKE_CURRENT_SOURCE_DIR}/runner/resources/app_icon.png"
  DESTINATION "${INSTALL_BUNDLE_DATA_DIR}" COMPONENT Runtime)

foreach(bundled_library ${PLUGIN_BUNDLED_LIBRARIES})
  install(FILES "${bundled_library}"
    DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    COMPONENT Runtime)
endforeach(bundled_library)

# Copy the native assets provided by the build.dart from all packages.
set(NATIVE_ASSETS_DIR "${PROJECT_BUILD_DIR}native_assets/linux/")
install(DIRECTORY "${NATIVE_ASSETS_DIR}"
   DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
   COMPONENT Runtime)

# Fully re-copy the assets directory on each build to avoid having stale files
# from a previous install.
set(FLUTTER_ASSET_DIR_NAME "flutter_assets")
install(CODE "
  file(REMOVE_RECURSE \"${INSTALL_BUNDLE_DATA_DIR}/${FLUTTER_ASSET_DIR_NAME}\")
  " COMPONENT Runtime)
install(DIRECTORY "${PROJECT_BUILD_DIR}/${FLUTTER_ASSET_DIR_NAME}"
  DESTINATION "${INSTALL_BUNDLE_DATA_DIR}" COMPONENT Runtime)

# Install the AOT library on non-Debug builds only.
if(NOT CMAKE_BUILD_TYPE MATCHES "Debug")
  install(FILES "${AOT_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    COMPONENT Runtime)
endif()

# === Rust conversion core (libxdremux_core.so) ===
# Installed into the bundle's lib/ directory next to libflutter_linux_gtk.so so
# the Dart FFI loader (XdRemuxFFI._openLinux) finds it at
# <bundle>/lib/libxdremux_core.so. Override the source with
# XDREMUX_LINUX_RUST_LIB, matching the Windows XDREMUX_WINDOWS_RUST_DLL flow.
set(XDREMUX_RUST_SO
  "${CMAKE_CURRENT_SOURCE_DIR}/../../../target/release/libxdremux_core.so")
if(DEFINED ENV{XDREMUX_LINUX_RUST_LIB} AND NOT "$ENV{XDREMUX_LINUX_RUST_LIB}" STREQUAL "")
  file(TO_CMAKE_PATH "$ENV{XDREMUX_LINUX_RUST_LIB}" XDREMUX_RUST_SO)
  if(NOT EXISTS "${XDREMUX_RUST_SO}")
    message(FATAL_ERROR "Explicit Rust core library does not exist: ${XDREMUX_RUST_SO}")
  endif()
elseif(NOT EXISTS "${XDREMUX_RUST_SO}")
  # Development fallback: an unoptimized cargo build also works for local runs.
  set(XDREMUX_RUST_SO
    "${CMAKE_CURRENT_SOURCE_DIR}/../../../target/debug/libxdremux_core.so")
endif()
if(EXISTS "${XDREMUX_RUST_SO}")
  # The Dart loader opens this by absolute path, but the runner also carries
  # $ORIGIN/lib in its runpath so the library can be found by bare soname.
  install(FILES "${XDREMUX_RUST_SO}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    COMPONENT Runtime)
else()
  message(WARNING
    "Rust core library not found (looked in target/release and target/debug). "
    "Build it with: cargo build -p xdremux-core --release")
endif()
