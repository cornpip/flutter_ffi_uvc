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
