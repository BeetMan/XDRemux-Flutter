cmake_minimum_required(VERSION 3.13)
project(runner LANGUAGES CXX)

# Define the application target. To change its name, change BINARY_NAME in the
# top-level CMakeLists.txt, not the value here, or `flutter run` will no longer
# work.
#
# Any new source files that you add to the application should be added here.
#
# The parent project filters the generated plugin registrant (see
# ../CMakeLists.txt: tray_manager and jni are removed from the Linux build) and
# passes the filtered path down; fall back to Flutter's file if it is absent.
set(XDREMUX_PLUGIN_REGISTRANT
  "${FLUTTER_MANAGED_DIR}/generated_plugin_registrant.cc")
if(DEFINED XDREMUX_FILTERED_PLUGIN_REGISTRANT
   AND EXISTS "${XDREMUX_FILTERED_PLUGIN_REGISTRANT}")
  set(XDREMUX_PLUGIN_REGISTRANT "${XDREMUX_FILTERED_PLUGIN_REGISTRANT}")
endif()

add_executable(${BINARY_NAME}
  "main.cc"
  "my_application.cc"
  "${XDREMUX_PLUGIN_REGISTRANT}"
)

# Apply the standard set of build settings. This can be removed for applications
# that need different build settings.
apply_standard_settings(${BINARY_NAME})

# Add preprocessor definitions for the application ID.
add_definitions(-DAPPLICATION_ID="${APPLICATION_ID}")

# Add dependency libraries. Add any application-specific dependencies here.
target_link_libraries(${BINARY_NAME} PRIVATE flutter)
target_link_libraries(${BINARY_NAME} PRIVATE PkgConfig::GTK)

target_include_directories(${BINARY_NAME} PRIVATE "${CMAKE_SOURCE_DIR}")
