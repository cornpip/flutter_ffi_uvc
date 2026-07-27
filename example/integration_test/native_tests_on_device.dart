// On-device entry point for the native (C) behavior tests in ../native_test/.
//
// Recent Flutter versions only run tests on a real device or emulator when
// the entry file lives under integration_test/; running the native_test/
// files directly executes them on the host, where libflutter_ffi_uvc.so is
// not available.
import '../native_test/run_native_tests.dart' as tests;

void main() => tests.main();
