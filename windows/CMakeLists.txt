# The Flutter tooling requires that developers have a version of Visual Studio
# installed that includes CMake 3.14 or later.
cmake_minimum_required(VERSION 3.14)

# Project-level configuration.
set(PROJECT_NAME "flutter_ffi_uvc")
project(${PROJECT_NAME} LANGUAGES CXX)

# This value is used when generating builds using this plugin, so it must not
# be changed.
set(PLUGIN_NAME "flutter_ffi_uvc_plugin")

# Define the plugin library target. The Media Foundation backend implementing
# the Dart FFI surface (see ../src/include/flutter_ffi_uvc.h) lives in the same DLL so
# that Dart can open a single library for both FFI calls and channels.
add_library(${PLUGIN_NAME} SHARED
  "flutter_ffi_uvc_plugin.cpp"
  "flutter_ffi_uvc_plugin.h"
  "flutter_ffi_uvc_plugin_c_api.cpp"
  "uvc_mf_backend.cpp"
  "uvc_mf_backend.h"
)

apply_standard_settings(${PLUGIN_NAME})

set_target_properties(${PLUGIN_NAME} PROPERTIES
  CXX_VISIBILITY_PRESET hidden)
target_compile_definitions(${PLUGIN_NAME} PRIVATE FLUTTER_PLUGIN_IMPL)

# The backend uses std::vector growth and Win32/COM APIs that trip /WX under
# /W4; keep warnings visible but not fatal for plugin consumers.
target_compile_options(${PLUGIN_NAME} PRIVATE /WX-)

target_include_directories(${PLUGIN_NAME} INTERFACE
  "${CMAKE_CURRENT_SOURCE_DIR}/include")
target_link_libraries(${PLUGIN_NAME} PRIVATE flutter flutter_wrapper_plugin)
target_link_libraries(${PLUGIN_NAME} PRIVATE
  mf.lib
  mfplat.lib
  mfreadwrite.lib
  mfuuid.lib
  ole32.lib
  oleaut32.lib
  strmiids.lib
  user32.lib
)

# List of absolute paths to libraries that should be bundled with the plugin.
set(flutter_ffi_uvc_bundled_libraries
  ""
  PARENT_SCOPE
)
