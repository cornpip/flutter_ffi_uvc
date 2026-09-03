/// Test-only helpers. Not part of the supported API.
library;

import 'src/flutter_ffi_uvc_impl.dart';
import 'src/uvc_camera_api.dart';

/// Native session address of [camera], for test-only backend entry points.
int nativeSessionHandleOf(UvcCamera camera) =>
    (camera as FfiUvcCamera).nativeSessionHandle;
