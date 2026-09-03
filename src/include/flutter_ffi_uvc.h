#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdbool.h>

#if _WIN32
#include <windows.h>
#else
#include <pthread.h>
#include <unistd.h>
#endif

#if _WIN32
#define FFI_PLUGIN_EXPORT __declspec(dllexport)
#else
// Explicit default visibility so the symbols stay exported when the host
// library is built with -fvisibility=hidden (the Linux plugin build).
#define FFI_PLUGIN_EXPORT __attribute__((visibility("default")))
#endif

// The Windows backend implements this ABI in C++; the unmangled C names are
// what Dart FFI looks up in the plugin DLL.
#ifdef __cplusplus
extern "C" {
#endif

// One camera per session. Sessions share nothing except the log level.
// A NULL session behaves like a closed one. Int-returning calls return
// UVC_ERROR_INVALID_PARAM (-2), uvc_ctrl_get returns INT32_MIN, JSON writers
// return 0, and uvc_last_error returns "".
typedef struct uvc_session uvc_session_t;

// Allocates an idle session. Returns NULL on allocation failure.
FFI_PLUGIN_EXPORT uvc_session_t *uvc_session_create(void);

// Stops preview and recording, closes the device, and frees the session.
// Waits for every acquire pin to be released. No listener fires afterwards.
FFI_PLUGIN_EXPORT void uvc_session_destroy(uvc_session_t *session);

// For callers that hold a session pointer they do not own. uvc_session_acquire
// returns 1 and pins the session when the pointer is a live session, and 0
// for any other pointer. Pair every successful acquire with a release.
FFI_PLUGIN_EXPORT int uvc_session_acquire(uvc_session_t *session);
FFI_PLUGIN_EXPORT void uvc_session_release(uvc_session_t *session);

// Opens a device on the session. fd is a USB device node descriptor on
// Android and Linux and the enumeration device id on Windows. A device
// already open on this session is closed first.
FFI_PLUGIN_EXPORT int uvc_open_fd(uvc_session_t *session, int fd);

FFI_PLUGIN_EXPORT int uvc_start_preview(
    uvc_session_t *session,
    int frame_format,
    int width,
    int height,
    int fps);
FFI_PLUGIN_EXPORT void uvc_stop_preview(uvc_session_t *session);
FFI_PLUGIN_EXPORT void uvc_close_device(uvc_session_t *session);
FFI_PLUGIN_EXPORT int uvc_is_previewing(uvc_session_t *session);
FFI_PLUGIN_EXPORT int uvc_frame_width(uvc_session_t *session);
FFI_PLUGIN_EXPORT int uvc_frame_height(uvc_session_t *session);
FFI_PLUGIN_EXPORT int uvc_copy_latest_frame_rgba(
    uvc_session_t *session,
    uint8_t *buffer,
    int buffer_length);
FFI_PLUGIN_EXPORT int uvc_copy_latest_frame_rgba_with_metadata(
    uvc_session_t *session,
    uint8_t *buffer,
    int buffer_length,
    int *out_width,
    int *out_height,
    int64_t *out_sequence);
FFI_PLUGIN_EXPORT int uvc_copy_latest_frame_rgba_transformed(
    uvc_session_t *session,
    uint8_t *buffer,
    int buffer_length,
    int rotation,
    int flip_h,
    int flip_v,
    int *out_width,
    int *out_height,
    int64_t *out_sequence);
FFI_PLUGIN_EXPORT int64_t uvc_latest_frame_sequence(uvc_session_t *session);

// Listeners run on native threads and receive user_data unchanged. A NULL
// listener clears the slot. uvc_close_device keeps the frame listener and
// clears the error listener.
typedef void (*uvc_frame_listener_t)(void *user_data, int64_t sequence);
FFI_PLUGIN_EXPORT void uvc_set_frame_listener(
    uvc_session_t *session,
    uvc_frame_listener_t listener,
    void *user_data);
typedef void (*uvc_error_listener_t)(void *user_data, const char *message);
FFI_PLUGIN_EXPORT void uvc_set_error_listener(
    uvc_session_t *session,
    uvc_error_listener_t listener,
    void *user_data);

FFI_PLUGIN_EXPORT int uvc_get_stream_stats_json(
    uvc_session_t *session,
    uint8_t *buffer,
    int buffer_length);
FFI_PLUGIN_EXPORT int uvc_get_supported_modes_json(
    uvc_session_t *session,
    uint8_t *buffer,
    int buffer_length);

// Last error text of the session. Valid until the session is destroyed.
FFI_PLUGIN_EXPORT const char *uvc_last_error(uvc_session_t *session);

// Process-wide native log level (UVC_LOG_LEVEL_*).
FFI_PLUGIN_EXPORT void uvc_set_log_level(int level);

// Preview transform: rotation is 0, 90, 180, or 270 (clockwise degrees).
// flip_h mirrors the output left-right; flip_v mirrors it top-bottom.
// Transforms are applied during preview blit to the attached Flutter Texture
// and do not affect the RGBA buffer returned by copyLatestFrame.
FFI_PLUGIN_EXPORT void uvc_set_preview_transform(
    uvc_session_t *session,
    int rotation,
    int flip_h,
    int flip_v);

// Reads back the current preview transform. Desktop plugin layers use this to
// render the attached Flutter texture with the same transform the preview
// blit applies. Null out-pointers are allowed.
FFI_PLUGIN_EXPORT void uvc_get_preview_transform(
    uvc_session_t *session,
    int *rotation,
    int *flip_h,
    int *flip_v);

// Encodes the latest preview frame to JPEG.
// rotation/flip semantics match uvc_copy_latest_frame_rgba_transformed and are
// applied before encoding; quality is clamped to 1-100. Returns the number of
// JPEG bytes written to buffer, or 0 on failure (no frame yet, buffer too
// small, or encoder error; see uvc_last_error). out_width/out_height report
// the encoded (post-transform) dimensions; out_sequence reports the source
// frame sequence.
FFI_PLUGIN_EXPORT int uvc_take_picture_jpeg(
    uvc_session_t *session,
    uint8_t *buffer,
    int buffer_length,
    int quality,
    int rotation,
    int flip_h,
    int flip_v,
    int *out_width,
    int *out_height,
    int64_t *out_sequence);

// Video recording (MP4 / H.264).
//
// Records the session's preview stream to an MP4 file while the preview
// keeps running. Requires an active preview: the recording locks onto the
// current frame dimensions, and frames whose dimensions later stop matching
// (e.g. after a mode switch) are dropped. rotation/flip semantics match
// uvc_take_picture_jpeg and are captured at start; the transform stays fixed
// for the whole recording. Recording is finalized automatically when the
// preview stops or the device closes.
//
// path is UTF-8. bitrate_bps <= 0 selects a default from resolution and fps.
// fps_hint <= 0 defaults to 30; it seeds encoder rate control while sample
// timestamps always follow actual frame arrival times.
// Returns 0 on success or a negative libuvc-style error code.
FFI_PLUGIN_EXPORT int uvc_start_recording(
    uvc_session_t *session,
    const char *path,
    int bitrate_bps,
    int fps_hint,
    int rotation,
    int flip_h,
    int flip_v);

// Stops recording, drains the encoder, and finalizes the MP4 file.
// Returns 0 when the file was finalized, negative on failure. Calling with no
// active recording returns 0.
FFI_PLUGIN_EXPORT int uvc_stop_recording(uvc_session_t *session);

FFI_PLUGIN_EXPORT int uvc_is_recording(uvc_session_t *session);

// CT/PU camera control IDs
// PU (Processing Unit) controls: 1-19
#define UVC_CTRL_ID_BRIGHTNESS                  1
#define UVC_CTRL_ID_CONTRAST                    2
#define UVC_CTRL_ID_HUE                         3
#define UVC_CTRL_ID_SATURATION                  4
#define UVC_CTRL_ID_SHARPNESS                   5
#define UVC_CTRL_ID_GAMMA                       6
#define UVC_CTRL_ID_GAIN                        7
#define UVC_CTRL_ID_BACKLIGHT_COMPENSATION      8
#define UVC_CTRL_ID_WHITE_BALANCE_TEMPERATURE   9
#define UVC_CTRL_ID_WHITE_BALANCE_TEMP_AUTO     10
#define UVC_CTRL_ID_POWER_LINE_FREQUENCY        11
#define UVC_CTRL_ID_CONTRAST_AUTO               12
#define UVC_CTRL_ID_HUE_AUTO                    13
#define UVC_CTRL_ID_WHITE_BALANCE_COMPONENT_AUTO 14
#define UVC_CTRL_ID_DIGITAL_MULTIPLIER          15
#define UVC_CTRL_ID_DIGITAL_MULTIPLIER_LIMIT    16
#define UVC_CTRL_ID_ANALOG_VIDEO_STANDARD       17
#define UVC_CTRL_ID_ANALOG_LOCK_STATUS          18
// CT (Camera Terminal) controls: 20-39
#define UVC_CTRL_ID_EXPOSURE_ABS                20
#define UVC_CTRL_ID_AE_MODE                     21
#define UVC_CTRL_ID_AE_PRIORITY                 22
#define UVC_CTRL_ID_FOCUS_ABS                   23
#define UVC_CTRL_ID_FOCUS_AUTO                  24
#define UVC_CTRL_ID_ZOOM_ABS                    25
#define UVC_CTRL_ID_SCANNING_MODE               26
#define UVC_CTRL_ID_EXPOSURE_REL                27
#define UVC_CTRL_ID_IRIS_ABS                    28
#define UVC_CTRL_ID_IRIS_REL                    29
#define UVC_CTRL_ID_ROLL_ABS                    30
#define UVC_CTRL_ID_PRIVACY                     31
#define UVC_CTRL_ID_FOCUS_SIMPLE                32

// Returns JSON array of all controls the device supports, with min/max/def/cur/res fields.
// Returns number of bytes written, or 0 on failure.
FFI_PLUGIN_EXPORT int uvc_ctrl_get_all_json(uvc_session_t *session, uint8_t *buffer, int buffer_length);

// Returns JSON array of controls present in descriptor bmControls only.
// Debug helper: does not probe GET_CUR/GET_MIN/GET_MAX.
FFI_PLUGIN_EXPORT int uvc_ctrl_get_bm_controls_json(uvc_session_t *session, uint8_t *buffer, int buffer_length);

// Returns the current value of a control. Returns INT32_MIN on error.
FFI_PLUGIN_EXPORT int32_t uvc_ctrl_get(uvc_session_t *session, int ctrl_id);

// Sets a control value. Returns 0 (UVC_SUCCESS) on success, negative on error.
FFI_PLUGIN_EXPORT int uvc_ctrl_set(uvc_session_t *session, int ctrl_id, int32_t value);

// Compound controls that cannot be represented as a single integer value.
FFI_PLUGIN_EXPORT int uvc_get_white_balance_component_json(uvc_session_t *session, uint8_t *buffer, int buffer_length);
FFI_PLUGIN_EXPORT int uvc_set_white_balance_component_values(uvc_session_t *session, uint16_t blue, uint16_t red);
FFI_PLUGIN_EXPORT int uvc_get_focus_rel_json(uvc_session_t *session, uint8_t *buffer, int buffer_length);
FFI_PLUGIN_EXPORT int uvc_set_focus_rel_values(uvc_session_t *session, int8_t focus_rel, uint8_t speed);
FFI_PLUGIN_EXPORT int uvc_get_zoom_rel_json(uvc_session_t *session, uint8_t *buffer, int buffer_length);
FFI_PLUGIN_EXPORT int uvc_set_zoom_rel_values(uvc_session_t *session, int8_t zoom_rel, uint8_t digital_zoom, uint8_t speed);
FFI_PLUGIN_EXPORT int uvc_get_pantilt_abs_json(uvc_session_t *session, uint8_t *buffer, int buffer_length);
FFI_PLUGIN_EXPORT int uvc_set_pantilt_abs_values(uvc_session_t *session, int32_t pan, int32_t tilt);
FFI_PLUGIN_EXPORT int uvc_get_pantilt_rel_json(uvc_session_t *session, uint8_t *buffer, int buffer_length);
FFI_PLUGIN_EXPORT int uvc_set_pantilt_rel_values(uvc_session_t *session, int8_t pan_rel, uint8_t pan_speed, int8_t tilt_rel, uint8_t tilt_speed);
FFI_PLUGIN_EXPORT int uvc_get_roll_rel_json(uvc_session_t *session, uint8_t *buffer, int buffer_length);
FFI_PLUGIN_EXPORT int uvc_set_roll_rel_values(uvc_session_t *session, int8_t roll_rel, uint8_t speed);
FFI_PLUGIN_EXPORT int uvc_get_digital_window_json(uvc_session_t *session, uint8_t *buffer, int buffer_length);
FFI_PLUGIN_EXPORT int uvc_set_digital_window_values(
    uvc_session_t *session,
    uint16_t window_top,
    uint16_t window_left,
    uint16_t window_bottom,
    uint16_t window_right,
    uint16_t num_steps,
    uint16_t num_steps_units);
FFI_PLUGIN_EXPORT int uvc_get_region_of_interest_json(uvc_session_t *session, uint8_t *buffer, int buffer_length);
FFI_PLUGIN_EXPORT int uvc_set_region_of_interest_values(
    uvc_session_t *session,
    uint16_t roi_top,
    uint16_t roi_left,
    uint16_t roi_bottom,
    uint16_t roi_right,
    uint16_t auto_controls);

#ifdef __cplusplus
}
#endif
