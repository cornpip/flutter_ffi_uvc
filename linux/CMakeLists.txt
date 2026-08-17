# The Flutter tooling requires that developers have CMake 3.10 or later
# installed. You should not increase this version, as doing so will cause
# the plugin to fail to compile for some customers of the plugin.
cmake_minimum_required(VERSION 3.10)

# Project-level configuration.
set(PROJECT_NAME "flutter_ffi_uvc")
project(${PROJECT_NAME} LANGUAGES C CXX)

# This value is used when generating builds using this plugin, so it must not
# be changed.
set(PLUGIN_NAME "flutter_ffi_uvc_plugin")

# The libuvc backend implementing the Dart FFI surface (see
# ../src/include/flutter_ffi_uvc.h) lives in the same .so as the plugin so
# that Dart can open a single library for both FFI calls and channels,
# mirroring the Windows plugin DLL layout.
#
# libusb and libjpeg-turbo are vendored and built from source, so the build
# needs no system libraries beyond Flutter's own Linux requirements. nasm is
# optional: with it, libjpeg-turbo's x86_64 SIMD is enabled.
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
find_package(Threads REQUIRED)

add_subdirectory(
  "${CMAKE_CURRENT_SOURCE_DIR}/../src/backend_libuvc/third_party/libusb"
  libusb_build
)
# Wrapped as IMPORTED (like the Android prebuilt path) so libuvc's
# install(EXPORT) does not require the vendored target in its export set.
add_library(LibUSB::LibUSB SHARED IMPORTED GLOBAL)
set_target_properties(LibUSB::LibUSB PROPERTIES
  IMPORTED_LOCATION "${CMAKE_CURRENT_BINARY_DIR}/libusb_build/libusb1.0.so"
  INTERFACE_INCLUDE_DIRECTORIES
    "${CMAKE_CURRENT_SOURCE_DIR}/../src/backend_libuvc/third_party/libusb/libusb"
)

# libjpeg-turbo's CMake refuses add_subdirectory() integration, so build it
# as an external project and import the static archive under the JPEG::JPEG
# name that libuvc's FindJpegPkg.cmake honors.
set(FFI_UVC_JPEG_SRC
  "${CMAKE_CURRENT_SOURCE_DIR}/../src/backend_libuvc/third_party/libjpeg-turbo-src")
set(FFI_UVC_JPEG_BUILD "${CMAKE_CURRENT_BINARY_DIR}/libjpeg_turbo_build")
set(FFI_UVC_JPEG_SIMD ON)
if(CMAKE_SYSTEM_PROCESSOR MATCHES "x86_64|AMD64")
  find_program(FFI_UVC_NASM nasm)
  if(NOT FFI_UVC_NASM)
    message(STATUS
      "nasm not found; building libjpeg-turbo without x86_64 SIMD "
      "(install nasm for faster MJPEG decode)")
    set(FFI_UVC_JPEG_SIMD OFF)
  endif()
endif()

include(ExternalProject)
ExternalProject_Add(jpeg_turbo_external
  SOURCE_DIR "${FFI_UVC_JPEG_SRC}"
  BINARY_DIR "${FFI_UVC_JPEG_BUILD}"
  CMAKE_ARGS
    -DCMAKE_BUILD_TYPE=Release
    -DCMAKE_C_COMPILER=${CMAKE_C_COMPILER}
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON
    -DENABLE_SHARED=OFF
    -DENABLE_STATIC=ON
    -DWITH_TURBOJPEG=OFF
    -DWITH_SIMD=${FFI_UVC_JPEG_SIMD}
  BUILD_BYPRODUCTS "${FFI_UVC_JPEG_BUILD}/libjpeg.a"
  INSTALL_COMMAND ""
)
# jconfig.h lands in the external build dir; it must exist at configure time
# for the imported target's interface include check.
file(MAKE_DIRECTORY "${FFI_UVC_JPEG_BUILD}")

add_library(JPEG::JPEG STATIC IMPORTED GLOBAL)
set_target_properties(JPEG::JPEG PROPERTIES
  IMPORTED_LOCATION "${FFI_UVC_JPEG_BUILD}/libjpeg.a"
  INTERFACE_INCLUDE_DIRECTORIES
    "${FFI_UVC_JPEG_SRC}/src;${FFI_UVC_JPEG_BUILD}"
)

set(BUILD_EXAMPLE OFF CACHE BOOL "" FORCE)
set(BUILD_TEST OFF CACHE BOOL "" FORCE)
set(CMAKE_BUILD_TARGET Static CACHE STRING "" FORCE)
# EXCLUDE_FROM_ALL keeps libuvc's install rules out of the app bundle
# (uvc_static still builds because the plugin links it).
add_subdirectory(
  "${CMAKE_CURRENT_SOURCE_DIR}/../src/backend_libuvc/libuvc"
  libuvc_build
  EXCLUDE_FROM_ALL
)
# uvc_static compiles frame-mjpeg.c against the generated jconfig.h and
# links the vendored libusb archive.
add_dependencies(uvc_static jpeg_turbo_external usb_vendored)

add_library(${PLUGIN_NAME} SHARED
  "flutter_ffi_uvc_plugin.cc"
  "${CMAKE_CURRENT_SOURCE_DIR}/../src/backend_libuvc/flutter_ffi_uvc.c"
)

apply_standard_settings(${PLUGIN_NAME})

# The FFI entry points carry explicit default visibility in the header;
# the plugin's other symbols stay hidden.
set_target_properties(${PLUGIN_NAME} PROPERTIES
  CXX_VISIBILITY_PRESET hidden
  C_VISIBILITY_PRESET hidden
)
# The shared C backend also builds under the Android NDK; keep host-compiler
# warnings visible but not fatal.
set_source_files_properties(
  "${CMAKE_CURRENT_SOURCE_DIR}/../src/backend_libuvc/flutter_ffi_uvc.c"
  PROPERTIES COMPILE_OPTIONS "-Wno-error"
)
target_compile_definitions(${PLUGIN_NAME} PRIVATE FLUTTER_PLUGIN_IMPL)
target_compile_definitions(${PLUGIN_NAME} PRIVATE DART_SHARED_LIB)

target_include_directories(${PLUGIN_NAME} INTERFACE
  "${CMAKE_CURRENT_SOURCE_DIR}/include")
target_include_directories(${PLUGIN_NAME} PRIVATE
  "${CMAKE_CURRENT_SOURCE_DIR}/../src/include"
  "${CMAKE_CURRENT_SOURCE_DIR}/../src/backend_libuvc/libuvc/include"
  "${CMAKE_CURRENT_BINARY_DIR}/libuvc_build/include"
)

target_link_libraries(${PLUGIN_NAME} PRIVATE flutter)
target_link_libraries(${PLUGIN_NAME} PRIVATE PkgConfig::GTK)
target_link_libraries(${PLUGIN_NAME} PRIVATE
  LibUVC::UVCStatic
  JPEG::JPEG
  Threads::Threads
)
target_compile_definitions(${PLUGIN_NAME} PRIVATE FFI_UVC_HAS_JPEG=1)
add_dependencies(${PLUGIN_NAME} jpeg_turbo_external usb_vendored)

# The vendored libusb ships next to the plugin in the bundle's lib/
# directory; $ORIGIN lets the plugin resolve it from there. Flutter bundles
# the build-tree artifact, so the build rpath is what ships:
# BUILD_RPATH_USE_ORIGIN keeps the automatic entries $ORIGIN-relative
# instead of leaking build-machine absolute paths into the binary.
set_target_properties(${PLUGIN_NAME} PROPERTIES
  BUILD_RPATH_USE_ORIGIN TRUE
  BUILD_RPATH "$ORIGIN"
  INSTALL_RPATH "$ORIGIN"
)
# Link-time only: lets the app executable's linker resolve the plugin's
# libusb1.0.so dependency from the build tree. Nothing is embedded.
target_link_options(${PLUGIN_NAME} INTERFACE
  "-Wl,-rpath-link,${CMAKE_CURRENT_BINARY_DIR}/libusb_build")

# List of absolute paths to libraries that should be bundled with the plugin.
set(flutter_ffi_uvc_bundled_libraries
  "$<TARGET_FILE:usb_vendored>"
  PARENT_SCOPE
)
