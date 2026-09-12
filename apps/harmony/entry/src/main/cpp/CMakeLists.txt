cmake_minimum_required(VERSION 3.24)

project(XdRemuxNativeBridge)

# prepare_harmony_native.ps1 stages the already-built Rust cdylib here. The
# bridge intentionally links that artifact instead of compiling a second core.
get_filename_component(ENTRY_DIR "${CMAKE_CURRENT_LIST_DIR}/../../.." ABSOLUTE)
set(XDREMUX_CORE_SO "${ENTRY_DIR}/libs/arm64-v8a/libxdremux_core.so")
if(NOT EXISTS "${XDREMUX_CORE_SO}")
    message(FATAL_ERROR
        "Missing ${XDREMUX_CORE_SO}; run tools/ohos/prepare_harmony_native.ps1 first")
endif()

add_library(xdremux_core SHARED IMPORTED GLOBAL)
set_target_properties(xdremux_core PROPERTIES
    IMPORTED_LOCATION "${XDREMUX_CORE_SO}"
    IMPORTED_NO_SONAME TRUE
)

add_library(entry SHARED napi_bridge.cpp)
target_compile_features(entry PRIVATE cxx_std_17)
target_compile_options(entry PRIVATE -Wall -Wextra)
target_link_libraries(entry PUBLIC xdremux_core libace_napi.z.so)
