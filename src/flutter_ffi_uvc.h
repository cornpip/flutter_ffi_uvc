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
#define FFI_PLUGIN_EXPORT
#endif

// A very short-lived native function.
//
// For very short-lived functions, it is fine to call them on the main isolate.
// They will block the Dart execution while running the native function, so
// only do this for native functions which are guaranteed to be short-lived.
FFI_PLUGIN_EXPORT int sum(int a, int b);

// A longer lived native function, which occupies the thread calling it.
//
// Do not call these kind of native functions in the main isolate. They will
// block Dart execution. This will cause dropped frames in Flutter applications.
// Instead, call these native functions on a separate isolate.
FFI_PLUGIN_EXPORT int sum_long_running(int a, int b);

FFI_PLUGIN_EXPORT int uvc_open_fd(int fd);
FFI_PLUGIN_EXPORT int uvc_start_preview(int frame_format, int width, int height, int fps);
FFI_PLUGIN_EXPORT void uvc_stop_preview(void);
FFI_PLUGIN_EXPORT void uvc_close_device(void);
FFI_PLUGIN_EXPORT int uvc_is_previewing(void);
FFI_PLUGIN_EXPORT int uvc_frame_width(void);
FFI_PLUGIN_EXPORT int uvc_frame_height(void);
FFI_PLUGIN_EXPORT int uvc_copy_latest_frame_rgba(uint8_t *buffer, int buffer_length);
FFI_PLUGIN_EXPORT int uvc_get_supported_modes_json(uint8_t *buffer, int buffer_length);
FFI_PLUGIN_EXPORT const char *uvc_last_error(void);
FFI_PLUGIN_EXPORT void uvc_set_log_level(int level);

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
FFI_PLUGIN_EXPORT int uvc_ctrl_get_all_json(uint8_t *buffer, int buffer_length);

// Returns JSON array of controls present in descriptor bmControls only.
// Debug helper: does not probe GET_CUR/GET_MIN/GET_MAX.
FFI_PLUGIN_EXPORT int uvc_ctrl_get_bm_controls_json(uint8_t *buffer, int buffer_length);

// Returns the current value of a control. Returns INT32_MIN on error.
FFI_PLUGIN_EXPORT int32_t uvc_ctrl_get(int ctrl_id);

// Sets a control value. Returns 0 (UVC_SUCCESS) on success, negative on error.
FFI_PLUGIN_EXPORT int uvc_ctrl_set(int ctrl_id, int32_t value);

// Compound controls that cannot be represented as a single integer value.
FFI_PLUGIN_EXPORT int uvc_get_white_balance_component_json(uint8_t *buffer, int buffer_length);
FFI_PLUGIN_EXPORT int uvc_set_white_balance_component_values(uint16_t blue, uint16_t red);
FFI_PLUGIN_EXPORT int uvc_get_focus_rel_json(uint8_t *buffer, int buffer_length);
FFI_PLUGIN_EXPORT int uvc_set_focus_rel_values(int8_t focus_rel, uint8_t speed);
FFI_PLUGIN_EXPORT int uvc_get_zoom_rel_json(uint8_t *buffer, int buffer_length);
FFI_PLUGIN_EXPORT int uvc_set_zoom_rel_values(int8_t zoom_rel, uint8_t digital_zoom, uint8_t speed);
FFI_PLUGIN_EXPORT int uvc_get_pantilt_abs_json(uint8_t *buffer, int buffer_length);
FFI_PLUGIN_EXPORT int uvc_set_pantilt_abs_values(int32_t pan, int32_t tilt);
FFI_PLUGIN_EXPORT int uvc_get_pantilt_rel_json(uint8_t *buffer, int buffer_length);
FFI_PLUGIN_EXPORT int uvc_set_pantilt_rel_values(int8_t pan_rel, uint8_t pan_speed, int8_t tilt_rel, uint8_t tilt_speed);
FFI_PLUGIN_EXPORT int uvc_get_roll_rel_json(uint8_t *buffer, int buffer_length);
FFI_PLUGIN_EXPORT int uvc_set_roll_rel_values(int8_t roll_rel, uint8_t speed);
FFI_PLUGIN_EXPORT int uvc_get_digital_window_json(uint8_t *buffer, int buffer_length);
FFI_PLUGIN_EXPORT int uvc_set_digital_window_values(
    uint16_t window_top,
    uint16_t window_left,
    uint16_t window_bottom,
    uint16_t window_right,
    uint16_t num_steps,
    uint16_t num_steps_units);
FFI_PLUGIN_EXPORT int uvc_get_region_of_interest_json(uint8_t *buffer, int buffer_length);
FFI_PLUGIN_EXPORT int uvc_set_region_of_interest_values(
    uint16_t roi_top,
    uint16_t roi_left,
    uint16_t roi_bottom,
    uint16_t roi_right,
    uint16_t auto_controls);
