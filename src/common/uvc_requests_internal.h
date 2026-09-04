// Backend-facing side of the request queue in uvc_requests.cpp. Not part
// of the Dart-facing ABI.
#ifndef FLUTTER_FFI_UVC_REQUESTS_INTERNAL_H_
#define FLUTTER_FFI_UVC_REQUESTS_INTERNAL_H_

#include "../include/flutter_ffi_uvc.h"

#ifdef __cplusplus
extern "C" {
#endif

// Called by uvc_session_destroy while the session is still live, before it
// closes the device. Interrupts the request in progress, joins the worker,
// completes the queued requests with UVC_ERROR_NO_DEVICE, closes the device
// so the platform gets device_released, and reports session_destroyed.
// Returns at once for a session that never made a request. Safe to call
// more than once.
void uvc_requests_shutdown(uvc_session_t *session);

#ifdef __cplusplus
}
#endif

#endif  // FLUTTER_FFI_UVC_REQUESTS_INTERNAL_H_
