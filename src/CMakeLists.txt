# The Flutter tooling requires that developers have CMake 3.10 or later
# installed. You should not increase this version, as doing so will cause
# the plugin to fail to compile for some customers of the plugin.
cmake_minimum_required(VERSION 3.10)

project(flutter_ffi_uvc_library VERSION 0.0.1 LANGUAGES C)

# Build libuvc as part of the plugin so Flutter bundles a single native library.
set(BUILD_EXAMPLE OFF CACHE BOOL "" FORCE)
set(BUILD_TEST OFF CACHE BOOL "" FORCE)
set(CMAKE_BUILD_TARGET Static CACHE STRING "" FORCE)

if(ANDROID AND NOT TARGET LibUSB::LibUSB)
  set(LIBUSB_ANDROID_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/third_party/libusb-android")
  set(LIBUSB_ANDROID_INCLUDE_DIR "${LIBUSB_ANDROID_ROOT}/include")
  set(LIBUSB_ANDROID_LIBRARY "${LIBUSB_ANDROID_ROOT}/${ANDROID_ABI}/libusb1.0.so")

  if(DEFINED LIBUSB_INCLUDE_DIR AND DEFINED LIBUSB_LIBRARY)
    add_library(LibUSB::LibUSB SHARED IMPORTED)
    set_target_properties(LibUSB::LibUSB PROPERTIES
      IMPORTED_LOCATION "${LIBUSB_LIBRARY}"
      INTERFACE_INCLUDE_DIRECTORIES "${LIBUSB_INCLUDE_DIR}"
    )
  elseif(EXISTS "${LIBUSB_ANDROID_INCLUDE_DIR}/libusb.h" AND EXISTS "${LIBUSB_ANDROID_LIBRARY}")
    add_library(LibUSB::LibUSB SHARED IMPORTED)
    set_target_properties(LibUSB::LibUSB PROPERTIES
      IMPORTED_LOCATION "${LIBUSB_ANDROID_LIBRARY}"
      INTERFACE_INCLUDE_DIRECTORIES "${LIBUSB_ANDROID_INCLUDE_DIR}"
    )
  else()
    message(FATAL_ERROR
      "libuvc needs libusb on Android. Provide -DLIBUSB_INCLUDE_DIR and "
      "-DLIBUSB_LIBRARY to CMake, or vendor a prebuilt at "
      "src/third_party/libusb-android/<abi>/libusb1.0.so with headers in "
      "src/third_party/libusb-android/include."
    )
  endif()
endif()

if(ANDROID AND NOT TARGET JPEG::JPEG)
  set(JPEG_TURBO_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/third_party/libjpeg-turbo")
  set(JPEG_TURBO_COMMON_INCLUDE_DIR "${JPEG_TURBO_ROOT}/include")

  if(ANDROID_ABI STREQUAL "arm64-v8a")
    set(JPEG_TURBO_ANDROID_BUILD_DIR "${JPEG_TURBO_ROOT}/arm64-v8a")
  elseif(ANDROID_ABI STREQUAL "armeabi-v7a")
    set(JPEG_TURBO_ANDROID_BUILD_DIR "${JPEG_TURBO_ROOT}/armeabi-v7a")
  elseif(ANDROID_ABI STREQUAL "x86_64")
    set(JPEG_TURBO_ANDROID_BUILD_DIR "${JPEG_TURBO_ROOT}/x86_64")
  endif()

  if(DEFINED JPEG_TURBO_ANDROID_BUILD_DIR
     AND EXISTS "${JPEG_TURBO_COMMON_INCLUDE_DIR}/jpeglib.h"
     AND EXISTS "${JPEG_TURBO_ANDROID_BUILD_DIR}/include/jconfig.h"
     AND EXISTS "${JPEG_TURBO_ANDROID_BUILD_DIR}/include/jconfigint.h"
     AND EXISTS "${JPEG_TURBO_ANDROID_BUILD_DIR}/libjpeg.so")
    add_library(JPEG::JPEG SHARED IMPORTED)
    set_target_properties(JPEG::JPEG PROPERTIES
      IMPORTED_LOCATION "${JPEG_TURBO_ANDROID_BUILD_DIR}/libjpeg.so"
      INTERFACE_INCLUDE_DIRECTORIES
        "${JPEG_TURBO_COMMON_INCLUDE_DIR};${JPEG_TURBO_ANDROID_BUILD_DIR}/include"
    )
    message(STATUS "Using vendored libjpeg-turbo for ${ANDROID_ABI}.")
  else()
    message(STATUS
      "Vendored libjpeg-turbo prebuilt not available for ${ANDROID_ABI}; "
      "libuvc JPEG support will use normal discovery or remain disabled."
    )
  endif()
endif()

add_subdirectory(libuvc)

add_library(flutter_ffi_uvc SHARED
  "flutter_ffi_uvc.c"
)

set_target_properties(flutter_ffi_uvc PROPERTIES
  PUBLIC_HEADER flutter_ffi_uvc.h
  OUTPUT_NAME "flutter_ffi_uvc"
)

target_compile_definitions(flutter_ffi_uvc PUBLIC DART_SHARED_LIB)
target_link_libraries(flutter_ffi_uvc PRIVATE LibUVC::UVCStatic)
target_include_directories(flutter_ffi_uvc PRIVATE
  "${CMAKE_CURRENT_SOURCE_DIR}/libuvc/include"
  "${CMAKE_CURRENT_BINARY_DIR}/libuvc/include"
)

if (ANDROID)
  # Support Android 15 16k page size
  target_link_options(flutter_ffi_uvc PRIVATE "-Wl,-z,max-page-size=16384")
  target_link_libraries(flutter_ffi_uvc PRIVATE android log)
endif()
