## Native tests

`native_test/` contains tests that verify native (C) behavior. A connected Android device or emulator is required, but no UVC camera is needed.

- `transform_test.dart` — verifies that `copyLatestFrameTransformed` produces correct pixel output for all rotation and flip combinations.
- `takepicture_test.dart` — verifies that `takePicture` produces valid, decodable JPEG output with correct dimensions and quality behavior.
- `streaming_error_test.dart` — verifies that native error callbacks are delivered correctly to `streamErrors`.

Run all native tests on a connected device or emulator through the
`integration_test/` wrapper (recent Flutter versions only run device tests
from that directory; find the device ID with `flutter devices`):

```sh
flutter test -d <device-id> integration_test/native_tests_on_device.dart
```

## macOS camera smoke test

`integration_test/macos_camera_smoke_test.dart` runs the public API against a
real camera on macOS: permission, device list, open, preview on a texture,
frame copies, still picture, MP4 recording, preview restart, close. It needs
a UVC camera attached, uses the first one listed, and is not part of CI. Run
it by hand after a change to the Apple backend.

```sh
flutter test -d macos integration_test/macos_camera_smoke_test.dart
```

Started this way the example is a child process of the terminal, and macOS
can refuse it camera access without showing a prompt. If the test fails at
the permission step, build the test into the app and start the app on its
own, so that it asks for camera access itself:

```sh
flutter build macos --debug -t integration_test/macos_camera_smoke_test.dart
open --stdout /tmp/uvc_smoke.log --stderr /tmp/uvc_smoke.log build/macos/Build/Products/Debug/flutter_ffi_uvc_example.app
```

The app stays open after the test. The result is the last line of
`/tmp/uvc_smoke.log`, `All tests passed!` or `Some tests failed.`, and the
`[smoke ...]` lines above it show each step. Quit the app afterwards. The
next `flutter run` or `flutter build` puts the normal example back.
