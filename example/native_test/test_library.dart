import 'dart:ffi' as ffi;
import 'dart:io';

/// Opens the package's native library for test-only symbol lookups.
///
/// Android exposes the FFI surface from libflutter_ffi_uvc.so; on Linux the
/// same backend is compiled into the plugin library. Windows is not covered:
/// the Media Foundation backend does not implement the test-injection entry
/// points these tests rely on.
ffi.DynamicLibrary openNativeTestLibrary() {
  if (Platform.isLinux) {
    return ffi.DynamicLibrary.open('libflutter_ffi_uvc_plugin.so');
  }
  return ffi.DynamicLibrary.open('libflutter_ffi_uvc.so');
}
