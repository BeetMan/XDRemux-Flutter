# Project-level configuration.
cmake_minimum_required(VERSION 3.14)
project(xdremux LANGUAGES CXX)

# The name of the executable created for the application. Change this to change
# the on-disk name of your application.
set(BINARY_NAME "xdremux")

# Explicitly opt in to modern CMake behaviors to avoid warnings with recent
# versions of CMake.
cmake_policy(VERSION 3.14...3.25)

# Define build configuration option.
get_property(IS_MULTICONFIG GLOBAL PROPERTY GENERATOR_IS_MULTI_CONFIG)
if(IS_MULTICONFIG)
  set(CMAKE_CONFIGURATION_TYPES "Debug;Profile;Release"
    CACHE STRING "" FORCE)
else()
  if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
    set(CMAKE_BUILD_TYPE "Debug" CACHE
      STRING "Flutter build mode" FORCE)
    set_property(CACHE CMAKE_BUILD_TYPE PROPERTY STRINGS
      "Debug" "Profile" "Release")
  endif()
endif()
# Define settings for the Profile build mode.
set(CMAKE_EXE_LINKER_FLAGS_PROFILE "${CMAKE_EXE_LINKER_FLAGS_RELEASE}")
set(CMAKE_SHARED_LINKER_FLAGS_PROFILE "${CMAKE_SHARED_LINKER_FLAGS_RELEASE}")
set(CMAKE_C_FLAGS_PROFILE "${CMAKE_C_FLAGS_RELEASE}")
set(CMAKE_CXX_FLAGS_PROFILE "${CMAKE_CXX_FLAGS_RELEASE}")

# Use Unicode for all projects.
add_definitions(-DUNICODE -D_UNICODE)

# Compilation settings that should be applied to most targets.
#
# Be cautious about adding new options here, as plugins use this function by
# default. In most cases, you should add new options to specific targets instead
# of modifying this function.
function(APPLY_STANDARD_SETTINGS TARGET)
  target_compile_features(${TARGET} PUBLIC cxx_std_17)
  # /utf-8 makes MSVC parse sources as UTF-8 regardless of the system code
  # page. Without it, UTF-8 sources (win32_window.cpp, Runner.rc) trip C4819
  # on CJK (code page 936) systems, and /WX turns that into a hard error.
  target_compile_options(${TARGET} PRIVATE /W4 /WX /utf-8 /wd"4100")
  target_compile_options(${TARGET} PRIVATE /EHsc)
  target_compile_definitions(${TARGET} PRIVATE "_HAS_EXCEPTIONS=0")
  target_compile_definitions(${TARGET} PRIVATE "_SILENCE_EXPERIMENTAL_COROUTINE_DEPRECATION_WARNINGS")
  target_compile_definitions(${TARGET} PRIVATE "$<$<CONFIG:Debug>:_DEBUG>")
endfunction()

# Flutter library and tool build rules.
set(FLUTTER_MANAGED_DIR "${CMAKE_CURRENT_SOURCE_DIR}/flutter")
add_subdirectory(${FLUTTER_MANAGED_DIR})

# Application build; see runner/CMakeLists.txt.
add_subdirectory("runner")


# Generated plugin build rules, which manage building the plugins and adding
# them to the application.
# Android path_provider's JNI FFI plugin must not introduce a desktop JVM.
# Filter a build-directory copy, preserving Flutter's generated source file.
file(READ "${CMAKE_CURRENT_SOURCE_DIR}/flutter/generated_plugins.cmake" XDREMUX_WINDOWS_PLUGINS)
string(REGEX REPLACE "\n[ \t]+jni[ \t]*\r?\n" "\n"
  XDREMUX_WINDOWS_PLUGINS "${XDREMUX_WINDOWS_PLUGINS}")
file(WRITE "${CMAKE_CURRENT_BINARY_DIR}/xdremux_windows_plugins.cmake" "${XDREMUX_WINDOWS_PLUGINS}")
include("${CMAKE_CURRENT_BINARY_DIR}/xdremux_windows_plugins.cmake")

# flutter_local_notifications_windows 2.x compiles WinRT headers under C++17,
# which trips VS2026's hard error on deprecated <experimental/coroutine>.
# The silencing define in APPLY_STANDARD_SETTINGS only covers the runner
# target, so add it to the plugin's shared library target directly.
if(TARGET flutter_local_notifications_windows)
  target_compile_definitions(flutter_local_notifications_windows
    PRIVATE "_SILENCE_EXPERIMENTAL_COROUTINE_DEPRECATION_WARNINGS")
endif()


# === Installation ===
# Support files are copied into place next to the executable, so that it can
# run in place. This is done instead of making a separate bundle (as on Linux)
# so that building and running from within Visual Studio will work.
set(BUILD_BUNDLE_DIR "$<TARGET_FILE_DIR:${BINARY_NAME}>")
# Make the "install" step default, as it's required to run.
set(CMAKE_VS_INCLUDE_INSTALL_TO_DEFAULT_BUILD 1)
if(CMAKE_INSTALL_PREFIX_INITIALIZED_TO_DEFAULT)
  set(CMAKE_INSTALL_PREFIX "${BUILD_BUNDLE_DIR}" CACHE PATH "..." FORCE)
endif()

set(INSTALL_BUNDLE_DATA_DIR "${CMAKE_INSTALL_PREFIX}/data")
set(INSTALL_BUNDLE_LIB_DIR "${CMAKE_INSTALL_PREFIX}")

install(TARGETS ${BINARY_NAME} RUNTIME DESTINATION "${CMAKE_INSTALL_PREFIX}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_ICU_DATA_FILE}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
  COMPONENT Runtime)

if(PLUGIN_BUNDLED_LIBRARIES)
  install(FILES "${PLUGIN_BUNDLED_LIBRARIES}"
    DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    COMPONENT Runtime)
endif()

# Copy the Rust core DLL next to the executable so dart:ffi can load it.
set(XDREMUX_RUST_DLL "${CMAKE_CURRENT_SOURCE_DIR}/../../../target/release/xdremux_core.dll")
if(DEFINED ENV{XDREMUX_WINDOWS_RUST_DLL} AND NOT "$ENV{XDREMUX_WINDOWS_RUST_DLL}" STREQUAL "")
  file(TO_CMAKE_PATH "$ENV{XDREMUX_WINDOWS_RUST_DLL}" XDREMUX_RUST_DLL)
  if(NOT EXISTS "${XDREMUX_RUST_DLL}")
    message(FATAL_ERROR "Explicit Rust DLL does not exist: ${XDREMUX_RUST_DLL}")
  endif()
endif()
if(EXISTS "${XDREMUX_RUST_DLL}")
  install(FILES "${XDREMUX_RUST_DLL}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}" COMPONENT Runtime)
else()
  message(WARNING "Rust core DLL not found at ${XDREMUX_RUST_DLL}. Build it with: cargo build --release")
endif()

# Explicit opt-in packaging only; ordinary builds retain their existing setup.
if(DEFINED ENV{XDREMUX_WINDOWS_LIBHEIF_PREFIX} AND NOT "$ENV{XDREMUX_WINDOWS_LIBHEIF_PREFIX}" STREQUAL "")
  file(TO_CMAKE_PATH "$ENV{XDREMUX_WINDOWS_LIBHEIF_PREFIX}" XDREMUX_HEIF_PREFIX)
  foreach(codec_dll heif.dll libde265.dll)
    if(NOT EXISTS "${XDREMUX_HEIF_PREFIX}/bin/${codec_dll}")
      message(FATAL_ERROR "Native decode dependency missing: ${codec_dll}")
    endif()
    install(FILES "${XDREMUX_HEIF_PREFIX}/bin/${codec_dll}"
      DESTINATION "${INSTALL_BUNDLE_LIB_DIR}" COMPONENT Runtime)
  endforeach()
  if(NOT EXISTS "${XDREMUX_HEIF_PREFIX}/licenses")
    message(FATAL_ERROR "Native decode dependency license notices missing")
  endif()
  install(DIRECTORY "${XDREMUX_HEIF_PREFIX}/licenses/"
    DESTINATION "${INSTALL_BUNDLE_DATA_DIR}/licenses" COMPONENT Runtime)
  # App-local MSVC runtime: do not require a developer machine or global VC install.
  set(CMAKE_INSTALL_SYSTEM_RUNTIME_LIBS_SKIP TRUE)
  include(InstallRequiredSystemLibraries)
  if(NOT CMAKE_INSTALL_SYSTEM_RUNTIME_LIBS)
    message(FATAL_ERROR "MSVC redistributable runtime files were not found")
  endif()
  install(FILES ${CMAKE_INSTALL_SYSTEM_RUNTIME_LIBS}
    DESTINATION "${INSTALL_BUNDLE_LIB_DIR}" COMPONENT Runtime)
endif()

# ffmpeg is no longer bundled: HEVC encoding uses static-linked x265 and
# thumbnails use Rust FFI (embedded EXIF JPEG extraction).

# Copy the native assets provided by the build.dart from all packages.
set(NATIVE_ASSETS_DIR "${PROJECT_BUILD_DIR}native_assets/windows/")
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
install(FILES "${AOT_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  CONFIGURATIONS Profile;Release
  COMPONENT Runtime)
