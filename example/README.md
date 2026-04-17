# flutter_ffi_uvc example

`example` is the Android example app for the `flutter_ffi_uvc` plugin.

## Build note

The most recent Flutter version used to build this example app was `3.41.4`.

## Native tests

`native_test/` contains tests that verify native (C) behavior. A connected Android device or emulator is required, but no UVC camera is needed.

- `transform_test.dart` — verifies that `copyLatestFrameTransformed` produces correct pixel output for all rotation and flip combinations.
- `streaming_error_test.dart` — verifies that native error callbacks are delivered correctly to `streamErrors`.

Run all native tests with a connected device or emulator:

```sh
flutter test native_test/run_native_tests.dart
```

If multiple devices are connected, find the device ID with `flutter devices` and specify it with `-d`:

```sh
flutter test -d <device-id> native_test/run_native_tests.dart
```
