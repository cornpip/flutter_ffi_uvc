#include "flutter_ffi_uvc.h"

#include <inttypes.h>
#include <setjmp.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>
#include <time.h>

#if defined(FFI_UVC_HAS_JPEG)
#include <jpeglib.h>
#endif

#if defined(__ANDROID__)
#include <android/native_window.h>
#include <android/native_window_jni.h>
#include <fcntl.h>
#include <jni.h>
#include <libusb.h>
#include <media/NdkMediaCodec.h>
#include <media/NdkMediaFormat.h>
#include <media/NdkMediaMuxer.h>
#if defined(__aarch64__)
#include <arm_neon.h>
#endif
#endif

#include "libuvc/libuvc.h"
#include "libuvc/uvc_log.h"

int g_uvc_native_log_level = UVC_LOG_LEVEL_DEFAULT;

// libuvc only exposes this declaration when libusb version macros are visible.
uvc_error_t uvc_wrap(int sys_dev, uvc_context_t *context, uvc_device_handle_t **devh);

typedef struct {
  uint64_t start_monotonic_ns;
  uint64_t stop_monotonic_ns;
  uint64_t first_frame_latency_ns;
  uint64_t delivered_gap_sum_ns;
  uint64_t delivered_gap_max_ns;
  uint64_t last_delivered_monotonic_ns;
  uint32_t last_source_sequence;
  uint32_t has_last_source_sequence;
  uint64_t input_frame_count;
  uint64_t delivered_frame_count;
  uint64_t decode_success_count;
  uint64_t decode_failure_count;
  uint64_t callback_lock_drop_count;
  uint64_t warmup_drop_count;
  uint64_t stale_frame_count;
  uint64_t undersized_frame_count;
  uint64_t invalid_mjpeg_count;
  uint64_t buffer_allocation_failure_count;
  uint64_t preview_surface_failure_count;
  uint64_t conversion_failure_count;
  uint64_t gap_ring[256];
  uint32_t gap_ring_count;
  uint32_t gap_ring_next;
} ffi_uvc_stream_stats_t;

#if defined(__ANDROID__)
// H.264 preview decoder state built on NDK AMediaCodec.
typedef struct {
  AMediaCodec *codec;
  int configured_width;
  int configured_height;
  // Input is dropped until an IDR slice arrives.
  int awaiting_keyframe;
  int error_streak;
  // Output layout, refreshed on AMEDIACODEC_INFO_OUTPUT_FORMAT_CHANGED.
  int32_t out_color_format;
  int32_t out_stride;
  int32_t out_slice_height;
  int32_t out_width;
  int32_t out_height;
  // UVC 1.5 Encoding Unit id, or 0 when the device has none. Probed once per
  // H.264 preview session and kept across decoder recreations.
  uint8_t eu_unit_id;
  uint64_t last_idr_request_ns;
  // Conversion pacing. YUV to RGBA conversion runs for at most half the
  // callback time so the decoder input side is never starved. Skipped
  // outputs are released undisplayed.
  uint64_t last_convert_start_ns;
  uint64_t last_convert_duration_ns;
  uint64_t input_skip_count;    // AUs lost because no input buffer freed up
  uint64_t display_skip_count;  // decoded outputs released without display
  // Set under the main mutex. The frame callback performs the control
  // transfer after unlocking so USB round-trips never block API calls.
  int keyframe_request_due;
  // Source sequence of the last processed access unit, used to detect lost
  // access units.
  uint32_t last_au_sequence;
  int has_last_au_sequence;
} ffi_uvc_h264_decoder_t;

// MP4 recorder state built on AMediaCodec and AMediaMuxer.
typedef struct {
  AMediaCodec *codec;
  AMediaMuxer *muxer;
  int fd;
  pthread_t thread;
  int thread_started;
  int stop_requested;  // guarded by s->mutex
  int muxer_started;
  ssize_t video_track;
  int src_width, src_height;  // expected preview frame dimensions
  int out_width, out_height;  // post-transform (encoded) dimensions
  int rotation, flip_h, flip_v;
  int color_format;
  int32_t enc_stride, enc_slice_height;
  uint64_t base_ns;
  int has_base;
  int64_t last_sequence;
  int64_t last_pts_us;
  uint64_t frames_submitted;
  uint64_t frames_dropped;
  uint8_t *rgba_copy;         // snapshot of the shared frame
  uint8_t *rgba_transformed;  // rotated/flipped frame, when needed
} ffi_uvc_recording_t;
#endif

// One camera session. Everything below is private to the session. The only
// process-wide state in this file is g_uvc_native_log_level.
//
// Locking, in acquisition order:
//   mutex        the main mutex. Frame buffers, preview and recording flags,
//                stats, listeners, transform, decoder state.
//   usb_mutex    held across every USB control transfer and across
//                uvc_start_streaming / uvc_stop_streaming.
//   error_mutex  leaf lock for last_error. Never takes the others.
//   listener_mutex  leaf lock held while a listener slot is read, written,
//                or running. A listener must not call back into the ABI.
// devh is written only under both mutex and usb_mutex. A reader may hold either.
// The frame callback trylocks mutex and takes error_mutex, never usb_mutex.
// The stop path releases mutex before uvc_stop_streaming so the in-flight
// callback can return.
struct uvc_session {
  // Registry bookkeeping, guarded by g_registry_mutex rather than the locks below.
  struct uvc_session *registry_next;
  uint64_t id;
  int pin_count;
  int destroying;

  pthread_mutex_t mutex;
  pthread_mutex_t usb_mutex;
  pthread_mutex_t error_mutex;
  pthread_mutex_t listener_mutex;
  pthread_cond_t callback_cond;
  // Signaled after each delivered frame while a recording consumes frames.
  pthread_cond_t recording_cond;
  int recording_active;
  uvc_context_t *ctx;
  uvc_device_handle_t *devh;
  uvc_frame_t *rgb_frame;
  uint8_t *latest_rgba;
  size_t latest_rgba_bytes;
  int frame_width;
  int frame_height;
  int previewing;
  int stopping_preview;
  uint32_t callbacks_inflight;
  int64_t latest_sequence;
  // Guarded by listener_mutex.
  uvc_frame_listener_t frame_listener;
  void *frame_listener_user_data;
  uvc_error_listener_t error_listener;
  void *error_listener_user_data;
  uint32_t callback_count;
  uint32_t mjpeg_warmup_drop_remaining;
  char last_error[256];  // guarded by error_mutex
  // Copy handed to uvc_last_error callers, so a concurrent set_last_error
  // never tears the text they read. Written only by uvc_last_error.
  char last_error_snapshot[256];
  // Ring buffer so each pending async error callback gets its own stable slot.
  char error_ring[8][256];
  uint32_t error_ring_next;
#if defined(__ANDROID__)
  ANativeWindow *preview_window;
  ffi_uvc_h264_decoder_t h264;
  ffi_uvc_recording_t rec;
#endif
  int preview_rotation;  // 0, 90, 180, 270 (clockwise)
  int preview_flip_h;    // mirror left-right
  int preview_flip_v;    // mirror top-bottom
  ffi_uvc_stream_stats_t stats;
};

// Returned by uvc_last_error(NULL).
static const char k_empty_last_error[] = "";

// Session registry. Platform plugin layers hold raw session handles they do not
// own and use the registry to validate a handle and pin it for the duration of
// a call. uvc_session_destroy refuses new pins, waits for existing ones, then
// unlinks and frees. Pointers are only compared, never dereferenced, until found
// in the list, so a stale handle is safe.
static pthread_mutex_t g_registry_mutex = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t g_registry_cond = PTHREAD_COND_INITIALIZER;
static uvc_session_t *g_registry_head = NULL;
static uint64_t g_next_session_id = 1;

static int registry_contains_locked(const uvc_session_t *s) {
  for (uvc_session_t *it = g_registry_head; it != NULL; it = it->registry_next) {
    if (it == s) {
      return 1;
    }
  }
  return 0;
}

static uvc_session_t *registry_find_id_locked(uint64_t id) {
  for (uvc_session_t *it = g_registry_head; it != NULL; it = it->registry_next) {
    if (it->id == id) {
      return it;
    }
  }
  return NULL;
}

static void registry_add(uvc_session_t *s) {
  pthread_mutex_lock(&g_registry_mutex);
  s->id = g_next_session_id++;
  s->registry_next = g_registry_head;
  g_registry_head = s;
  pthread_mutex_unlock(&g_registry_mutex);
}

// Marks the session as going away, waits for pins to drain, and unlinks it.
// Returns 0 when the pointer was not a live session.
static int registry_retire(uvc_session_t *s) {
  pthread_mutex_lock(&g_registry_mutex);
  if (!registry_contains_locked(s) || s->destroying) {
    pthread_mutex_unlock(&g_registry_mutex);
    return 0;
  }
  s->destroying = 1;
  while (s->pin_count > 0) {
    pthread_cond_wait(&g_registry_cond, &g_registry_mutex);
  }
  uvc_session_t **link = &g_registry_head;
  while (*link != NULL && *link != s) {
    link = &(*link)->registry_next;
  }
  if (*link == s) {
    *link = s->registry_next;
  }
  pthread_mutex_unlock(&g_registry_mutex);
  return 1;
}

FFI_PLUGIN_EXPORT int uvc_session_acquire(uvc_session_t *session) {
  if (session == NULL) {
    return 0;
  }
  pthread_mutex_lock(&g_registry_mutex);
  const int live = registry_contains_locked(session) && !session->destroying;
  if (live) {
    session->pin_count += 1;
  }
  pthread_mutex_unlock(&g_registry_mutex);
  return live;
}

FFI_PLUGIN_EXPORT void uvc_session_release(uvc_session_t *session) {
  if (session == NULL) {
    return;
  }
  pthread_mutex_lock(&g_registry_mutex);
  if (registry_contains_locked(session) && session->pin_count > 0) {
    session->pin_count -= 1;
    if (session->pin_count == 0) {
      pthread_cond_broadcast(&g_registry_cond);
    }
  }
  pthread_mutex_unlock(&g_registry_mutex);
}

FFI_PLUGIN_EXPORT uint64_t uvc_session_id(uvc_session_t *session) {
  return session != NULL ? session->id : 0;
}

FFI_PLUGIN_EXPORT uvc_session_t *uvc_session_acquire_id(uint64_t id) {
  pthread_mutex_lock(&g_registry_mutex);
  uvc_session_t *s = registry_find_id_locked(id);
  if (s != NULL && !s->destroying) {
    s->pin_count += 1;
  } else {
    s = NULL;
  }
  pthread_mutex_unlock(&g_registry_mutex);
  return s;
}

#if defined(__ANDROID__)
static void h264_session_reset_locked(uvc_session_t *s);
#endif

static uint64_t monotonic_time_ns(void) {
  struct timespec ts;
  if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0) {
    return 0;
  }

  return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
}

static int compare_uint64_ascending(const void *lhs, const void *rhs) {
  const uint64_t a = *(const uint64_t *)lhs;
  const uint64_t b = *(const uint64_t *)rhs;
  if (a < b) {
    return -1;
  }
  if (a > b) {
    return 1;
  }
  return 0;
}

FFI_PLUGIN_EXPORT void uvc_set_log_level(int level) {
  if (level < UVC_LOG_LEVEL_ERROR) {
    g_uvc_native_log_level = UVC_LOG_LEVEL_ERROR;
    return;
  }

  if (level > UVC_LOG_LEVEL_TRACE) {
    g_uvc_native_log_level = UVC_LOG_LEVEL_TRACE;
    return;
  }

  g_uvc_native_log_level = level;
}

static const char *frame_format_name(enum uvc_frame_format format) {
  switch (format) {
    case UVC_FRAME_FORMAT_YUYV:
      return "YUYV";
    case UVC_FRAME_FORMAT_MJPEG:
      return "MJPEG";
    case UVC_FRAME_FORMAT_RGB:
      return "RGB";
    case UVC_FRAME_FORMAT_BGR:
      return "BGR";
    case UVC_FRAME_FORMAT_UYVY:
      return "UYVY";
    case UVC_FRAME_FORMAT_H264:
      return "H264";
    case UVC_FRAME_FORMAT_GRAY8:
      return "GRAY8";
    default:
      return "UNKNOWN";
  }
}

static enum uvc_frame_format format_desc_to_frame_format(const uvc_format_desc_t *format_desc) {
  if (format_desc == NULL) {
    return UVC_FRAME_FORMAT_UNKNOWN;
  }

  switch (format_desc->bDescriptorSubtype) {
    case UVC_VS_FORMAT_MJPEG:
      return UVC_FRAME_FORMAT_MJPEG;
    case UVC_VS_FORMAT_UNCOMPRESSED:
    case UVC_VS_FORMAT_FRAME_BASED:
      if (memcmp(format_desc->fourccFormat, "YUY2", 4) == 0) {
        return UVC_FRAME_FORMAT_YUYV;
      }
      if (memcmp(format_desc->fourccFormat, "UYVY", 4) == 0) {
        return UVC_FRAME_FORMAT_UYVY;
      }
      if (memcmp(format_desc->fourccFormat, "RGB ", 4) == 0) {
        return UVC_FRAME_FORMAT_RGB;
      }
      if (memcmp(format_desc->fourccFormat, "BGR ", 4) == 0) {
        return UVC_FRAME_FORMAT_BGR;
      }
      if (memcmp(format_desc->fourccFormat, "H264", 4) == 0) {
        return UVC_FRAME_FORMAT_H264;
      }
      return UVC_FRAME_FORMAT_UNKNOWN;
    default:
      return UVC_FRAME_FORMAT_UNKNOWN;
  }
}

static void format_fourcc_string(const uvc_format_desc_t *format_desc, char *output, size_t output_size) {
  if (output_size < 5) {
    return;
  }

  if (format_desc == NULL) {
    snprintf(output, output_size, "null");
    return;
  }

  for (int i = 0; i < 4; ++i) {
    char c = (char)format_desc->fourccFormat[i];
    output[i] = (c >= 32 && c <= 126) ? c : '.';
  }
  output[4] = '\0';
}

static int append_json(char *buffer, size_t buffer_length, size_t *offset, const char *format, ...) {
  if (*offset >= buffer_length) {
    return 0;
  }

  va_list args;
  va_start(args, format);
  int written = vsnprintf(buffer + *offset, buffer_length - *offset, format, args);
  va_end(args);

  if (written < 0 || (size_t)written >= buffer_length - *offset) {
    return 0;
  }

  *offset += (size_t)written;
  return 1;
}

// Safe from any thread with or without the main mutex held. Takes only
// error_mutex.
static void set_last_error(uvc_session_t *s, const char *format, ...) {
  if (s == NULL) {
    return;
  }
  va_list args;
  va_start(args, format);
  pthread_mutex_lock(&s->error_mutex);
  vsnprintf(s->last_error, sizeof(s->last_error), format, args);
  pthread_mutex_unlock(&s->error_mutex);
  va_end(args);
}

static void clear_last_error(uvc_session_t *s) {
  pthread_mutex_lock(&s->error_mutex);
  s->last_error[0] = '\0';
  pthread_mutex_unlock(&s->error_mutex);
}

// Copies last_error into the next error ring slot and returns that slot so an
// async error callback fired after unlocking keeps a stable message.
// Caller holds the main mutex.
static const char *stage_error_ring_locked(uvc_session_t *s) {
  const uint32_t ring_idx = s->error_ring_next++ % 8;
  pthread_mutex_lock(&s->error_mutex);
  snprintf(s->error_ring[ring_idx], 256, "%s", s->last_error);
  pthread_mutex_unlock(&s->error_mutex);
  return s->error_ring[ring_idx];
}

static void reset_stream_stats_locked(uvc_session_t *s) {
  memset(&s->stats, 0, sizeof(s->stats));
}

static void reset_frame_buffer_locked(uvc_session_t *s) {
  free(s->latest_rgba);
  s->latest_rgba = NULL;
  s->latest_rgba_bytes = 0;
  s->frame_width = 0;
  s->frame_height = 0;
  s->latest_sequence = 0;
  s->callback_count = 0;
}

static void blit_rgba_transform(
    const uint32_t *src, int src_w, int src_h,
    uint32_t *dst, int dst_stride,
    int rot, int fh, int fv) {
  const int out_w = (rot == 90 || rot == 270) ? src_h : src_w;
  const int out_h = (rot == 90 || rot == 270) ? src_w : src_h;

  if (rot == 0 && !fh && !fv) {
    const size_t row_bytes = (size_t)out_w * 4u;
    for (int row = 0; row < out_h; ++row) {
      memcpy(dst + (size_t)row * (size_t)dst_stride,
             src + (size_t)row * (size_t)src_w,
             row_bytes);
    }
  } else {
    for (int dr = 0; dr < out_h; ++dr) {
      const int eff_dr = fv ? (out_h - 1 - dr) : dr;
      for (int dc = 0; dc < out_w; ++dc) {
        const int eff_dc = fh ? (out_w - 1 - dc) : dc;
        int sr, sc;
        switch (rot) {
          case 90:  sr = (src_h - 1) - eff_dc; sc = eff_dr;             break;
          case 180: sr = (src_h - 1) - eff_dr; sc = (src_w - 1) - eff_dc; break;
          case 270: sr = eff_dc;               sc = (src_w - 1) - eff_dr; break;
          default:  sr = eff_dr;               sc = eff_dc;              break;
        }
        dst[(size_t)dr * (size_t)dst_stride + (size_t)dc] =
            src[(size_t)sr * (size_t)src_w + (size_t)sc];
      }
    }
  }
}

#if defined(__ANDROID__)
static void release_preview_window_locked(uvc_session_t *s) {
  if (s->preview_window == NULL) {
    return;
  }

  ANativeWindow_release(s->preview_window);
  s->preview_window = NULL;
}

static int render_latest_rgba_to_preview_surface_locked(uvc_session_t *s) {
  if (s->preview_window == NULL ||
      s->latest_rgba == NULL ||
      s->frame_width <= 0 ||
      s->frame_height <= 0) {
    return 1;
  }

  const int src_w = s->frame_width;
  const int src_h = s->frame_height;
  const int rot   = s->preview_rotation;
  const int fh    = s->preview_flip_h;
  const int fv    = s->preview_flip_v;

  const int out_w = (rot == 90 || rot == 270) ? src_h : src_w;
  const int out_h = (rot == 90 || rot == 270) ? src_w : src_h;

  if (ANativeWindow_setBuffersGeometry(
          s->preview_window,
          out_w,
          out_h,
          WINDOW_FORMAT_RGBA_8888) != 0) {
    s->stats.preview_surface_failure_count += 1;
    set_last_error(s, "Failed to configure preview surface geometry");
    return 0;
  }

  ANativeWindow_Buffer window_buffer;
  if (ANativeWindow_lock(s->preview_window, &window_buffer, NULL) != 0) {
    s->stats.preview_surface_failure_count += 1;
    set_last_error(s, "Failed to lock preview surface");
    return 0;
  }

  const uint32_t *src = (const uint32_t *)s->latest_rgba;
  uint32_t *dst = (uint32_t *)window_buffer.bits;
  const int dst_stride = window_buffer.stride;

  blit_rgba_transform(src, src_w, src_h, dst, dst_stride, rot, fh, fv);

  ANativeWindow_unlockAndPost(s->preview_window);
  return 1;
}
#endif

static void finish_callback_locked(uvc_session_t *s) {
  if (s->callbacks_inflight == 0) {
    return;
  }

  s->callbacks_inflight -= 1;
  if (s->callbacks_inflight == 0) {
    pthread_cond_broadcast(&s->callback_cond);
  }
}

static void wait_for_callbacks_locked(uvc_session_t *s) {
  while (s->callbacks_inflight > 0) {
    pthread_cond_wait(&s->callback_cond, &s->mutex);
  }
}

static int begin_stop_preview_locked(uvc_session_t *s, uvc_device_handle_t **devh_to_stop) {
  if (s->previewing && s->devh != NULL) {
    *devh_to_stop = s->devh;
    if (s->stats.start_monotonic_ns != 0 &&
        s->stats.stop_monotonic_ns == 0) {
      s->stats.stop_monotonic_ns = monotonic_time_ns();
    }
    s->previewing = 0;
    s->stopping_preview = 1;
    return 1;
  }

  return 0;
}

static void finish_stop_preview_locked(uvc_session_t *s) {
  wait_for_callbacks_locked(s);
#if defined(__ANDROID__)
  h264_session_reset_locked(s);
#endif
  reset_frame_buffer_locked(s);
  s->stopping_preview = 0;
}

static void close_device_resources_locked(uvc_session_t *s) {
#if defined(__ANDROID__)
  release_preview_window_locked(s);
  h264_session_reset_locked(s);
#endif

  if (s->rgb_frame != NULL) {
    UVC_LOGD("UVC_NATIVE", "close_device_resources_locked freeing rgb_frame=%p", (void *)s->rgb_frame);
    uvc_free_frame(s->rgb_frame);
    s->rgb_frame = NULL;
  }

  if (s->devh != NULL) {
    UVC_LOGD("UVC_NATIVE", "close_device_resources_locked closing device handle devh=%p", (void *)s->devh);
    uvc_close(s->devh);
    s->devh = NULL;
  }

  if (s->ctx != NULL) {
    UVC_LOGD("UVC_NATIVE", "close_device_resources_locked exiting uvc context ctx=%p", (void *)s->ctx);
    uvc_exit(s->ctx);
    s->ctx = NULL;
  }

  UVC_LOGD("UVC_NATIVE", "close_device_resources_locked resetting frame buffers");
  if (s->stats.start_monotonic_ns != 0 &&
      s->stats.stop_monotonic_ns == 0) {
    s->stats.stop_monotonic_ns = monotonic_time_ns();
  }
  reset_frame_buffer_locked(s);
  s->previewing = 0;
  s->stopping_preview = 0;
  // Listeners survive preview stops and device closes. They only change
  // through their set functions.
}

// Listeners run under listener_mutex, so clearing a slot returns only after
// a call in progress has finished. Callers hold no other session lock.
static void dispatch_frame(uvc_session_t *s, int64_t sequence) {
  pthread_mutex_lock(&s->listener_mutex);
  if (s->frame_listener != NULL) {
    s->frame_listener(s->frame_listener_user_data, sequence);
  }
  pthread_mutex_unlock(&s->listener_mutex);
}

static void dispatch_error(uvc_session_t *s, const char *message) {
  pthread_mutex_lock(&s->listener_mutex);
  if (s->error_listener != NULL) {
    s->error_listener(s->error_listener_user_data, message);
  }
  pthread_mutex_unlock(&s->listener_mutex);
}

static int ensure_rgb_frame_locked(uvc_session_t *s, size_t required_bytes) {
  if (required_bytes == 0) {
    set_last_error(s, "Invalid RGB frame size: %zu", required_bytes);
    return 0;
  }

  if (s->rgb_frame == NULL) {
    s->rgb_frame = uvc_allocate_frame(required_bytes);
    if (s->rgb_frame == NULL) {
      s->stats.buffer_allocation_failure_count += 1;
      set_last_error(s, "Failed to allocate RGB frame buffer (%zu bytes)", required_bytes);
      return 0;
    }
    return 1;
  }

  if (s->rgb_frame->data_bytes < required_bytes) {
    uint8_t *new_data = realloc(s->rgb_frame->data, required_bytes);
    if (new_data == NULL) {
      s->stats.buffer_allocation_failure_count += 1;
      set_last_error(s, "Failed to grow RGB frame buffer to %zu bytes", required_bytes);
      return 0;
    }
    s->rgb_frame->data = new_data;
    s->rgb_frame->data_bytes = required_bytes;
  }

  return 1;
}

static int update_latest_rgba_locked(uvc_session_t *s) {
  const size_t rgba_bytes = (size_t)s->rgb_frame->width * (size_t)s->rgb_frame->height * 4;

  if (s->latest_rgba_bytes != rgba_bytes) {
    uint8_t *new_buffer = realloc(s->latest_rgba, rgba_bytes);
    if (new_buffer == NULL) {
      s->stats.buffer_allocation_failure_count += 1;
      set_last_error(s, "Failed to allocate %zu bytes for preview frame", rgba_bytes);
      return 0;
    }
    s->latest_rgba = new_buffer;
    s->latest_rgba_bytes = rgba_bytes;
  }

  uint8_t *src = (uint8_t *)s->rgb_frame->data;
  uint8_t *dst = s->latest_rgba;
  const size_t pixel_count =
      (size_t)s->rgb_frame->width * (size_t)s->rgb_frame->height;

  for (size_t i = 0; i < pixel_count; ++i) {
    dst[i * 4 + 0] = src[i * 3 + 0];
    dst[i * 4 + 1] = src[i * 3 + 1];
    dst[i * 4 + 2] = src[i * 3 + 2];
    dst[i * 4 + 3] = 0xFF;
  }

  s->frame_width = s->rgb_frame->width;
  s->frame_height = s->rgb_frame->height;
  s->latest_sequence += 1;
  return 1;
}

static size_t expected_frame_bytes_for_format(const uvc_frame_t *frame) {
  if (frame == NULL) {
    return 0;
  }

  switch (frame->frame_format) {
    case UVC_FRAME_FORMAT_YUYV:
    case UVC_FRAME_FORMAT_UYVY:
      return (size_t)frame->width * (size_t)frame->height * 2;
    case UVC_FRAME_FORMAT_RGB:
    case UVC_FRAME_FORMAT_BGR:
      return (size_t)frame->width * (size_t)frame->height * 3;
    case UVC_FRAME_FORMAT_GRAY8:
      return (size_t)frame->width * (size_t)frame->height;
    case UVC_FRAME_FORMAT_MJPEG:
      return 4;
    default:
      return 0;
  }
}

static int has_mjpeg_soi_marker(const uvc_frame_t *frame) {
  const uint8_t *data;

  if (frame == NULL || frame->data == NULL || frame->data_bytes < 4) {
    return 0;
  }

  data = (const uint8_t *)frame->data;
  return data[0] == 0xFF && data[1] == 0xD8;
}

#if defined(__ANDROID__)

// ---------------------------------------------------------------------------
// H.264 preview decode (NDK AMediaCodec)
// ---------------------------------------------------------------------------
// libuvc delivers one H.264 access unit per frame callback; the hardware
// decoder turns it into YUV420, which is converted straight into latest_rgba
// so everything downstream (texture, copyLatestFrame, recording, stall
// detection) runs unchanged. Delivery bookkeeping counts decoder *output*
// frames, so the package's frame-verification model stays meaningful.

// MediaCodecInfo.CodecCapabilities color formats reported by decoders.
#define H264_COLOR_FORMAT_I420 19
#define H264_COLOR_FORMAT_NV12 21

// UVC 1.5 Encoding Unit: VC descriptor subtype and the control selector that
// forces the camera to emit a sync (IDR) frame.
#define UVC_VC_ENCODING_UNIT_SUBTYPE 0x07
#define UVC_EU_SYNC_REF_FRAME_CONTROL 0x0B

// Reactive keyframe requests (loss, decode errors) are rate-limited; the
// periodic request bounds how long undetectable reference corruption can
// smear the preview.
#define H264_IDR_REQUEST_MIN_INTERVAL_NS 500000000ull
#define H264_PERIODIC_IDR_INTERVAL_NS 2000000000ull

// Releases the decoder only; the Encoding Unit state survives so mid-stream
// decoder recreations keep the keyframe-request capability.
static void h264_decoder_release_locked(uvc_session_t *s) {
  if (s->h264.codec != NULL) {
    AMediaCodec_stop(s->h264.codec);
    AMediaCodec_delete(s->h264.codec);
  }
  const uint8_t eu_unit_id = s->h264.eu_unit_id;
  const uint64_t last_idr_request_ns = s->h264.last_idr_request_ns;
  memset(&s->h264, 0, sizeof(s->h264));
  s->h264.eu_unit_id = eu_unit_id;
  s->h264.last_idr_request_ns = last_idr_request_ns;
}

// Full reset at preview stop / device close.
static void h264_session_reset_locked(uvc_session_t *s) {
  h264_decoder_release_locked(s);
  memset(&s->h264, 0, sizeof(s->h264));
}

// Finds the H.264 Encoding Unit in the VideoControl interface descriptors.
// libuvc does not parse encoding units, so this walks the class-specific
// descriptors from libusb's cached configuration (no USB traffic). Returns
// the unit id, or 0 when the device has none.
static uint8_t h264_find_encoding_unit(uvc_device_handle_t *devh) {
  libusb_device_handle *usb_devh = uvc_get_libusb_handle(devh);
  if (usb_devh == NULL) {
    return 0;
  }
  libusb_device *usb_dev = libusb_get_device(usb_devh);
  if (usb_dev == NULL) {
    return 0;
  }
  struct libusb_config_descriptor *config = NULL;
  if (libusb_get_active_config_descriptor(usb_dev, &config) != 0 ||
      config == NULL) {
    return 0;
  }
  uint8_t unit_id = 0;
  for (uint8_t i = 0; i < config->bNumInterfaces && unit_id == 0; ++i) {
    const struct libusb_interface *interface = &config->interface[i];
    for (int a = 0; a < interface->num_altsetting && unit_id == 0; ++a) {
      const struct libusb_interface_descriptor *alt = &interface->altsetting[a];
      // CC_VIDEO / SC_VIDEOCONTROL
      if (alt->bInterfaceClass != 14 || alt->bInterfaceSubClass != 1) {
        continue;
      }
      const unsigned char *extra = alt->extra;
      int remaining = alt->extra_length;
      while (remaining >= 3) {
        const uint8_t length = extra[0];
        if (length < 3 || length > remaining) {
          break;
        }
        // CS_INTERFACE (0x24) + VC_ENCODING_UNIT: bUnitID at offset 3.
        if (extra[1] == 0x24 && extra[2] == UVC_VC_ENCODING_UNIT_SUBTYPE &&
            length >= 4) {
          unit_id = extra[3];
          break;
        }
        extra += length;
        remaining -= length;
      }
    }
  }
  libusb_free_config_descriptor(config);
  return unit_id;
}

// Asks the camera to emit an IDR frame now (EU_SYNC_REF_FRAME). Called
// without the main mutex held. The caller must keep devh open, either from
// the frame callback on the stream thread or by holding usb_mutex.
static void h264_request_keyframe(uvc_device_handle_t *devh,
                                  uint8_t eu_unit_id) {
  // bSyncFrameType=1 (IDR), wSyncFrameInterval=0 (single request),
  // bGradualDecoderRefresh=0.
  uint8_t payload[4] = {0x01, 0x00, 0x00, 0x00};
  const int result = uvc_set_ctrl(devh, eu_unit_id,
                                  UVC_EU_SYNC_REF_FRAME_CONTROL, payload,
                                  (int)sizeof(payload));
  if (result != (int)sizeof(payload)) {
    UVC_LOGD("UVC_NATIVE", "EU sync-frame request failed result=%d", result);
  }
}

// Rate-limited scheduling of a keyframe request; the transfer itself happens
// after the caller releases the mutex. Returns 1 when a request was queued.
static int h264_mark_keyframe_request_locked(uvc_session_t *s, uint64_t now_ns,
                                             uint64_t min_interval_ns) {
  if (s->h264.eu_unit_id == 0) {
    return 0;
  }
  if (s->h264.last_idr_request_ns != 0 &&
      now_ns - s->h264.last_idr_request_ns < min_interval_ns) {
    return 0;
  }
  s->h264.last_idr_request_ns = now_ns;
  s->h264.keyframe_request_due = 1;
  return 1;
}

// Scans an Annex-B elementary stream for an IDR slice (NAL type 5).
static int h264_contains_idr(const uint8_t *data, size_t len) {
  size_t i = 0;
  while (i + 4 <= len) {
    if (data[i] == 0 && data[i + 1] == 0) {
      size_t nal_start = 0;
      if (data[i + 2] == 1) {
        nal_start = i + 3;
      } else if (i + 5 <= len && data[i + 2] == 0 && data[i + 3] == 1) {
        nal_start = i + 4;
      }
      if (nal_start != 0 && nal_start < len) {
        if ((data[nal_start] & 0x1F) == 5) {
          return 1;
        }
        i = nal_start;
        continue;
      }
    }
    i += 1;
  }
  return 0;
}

static int h264_decoder_ensure_locked(uvc_session_t *s, int width, int height) {
  if (s->h264.codec != NULL && s->h264.configured_width == width &&
      s->h264.configured_height == height) {
    return 1;
  }
  h264_decoder_release_locked(s);

  AMediaCodec *codec = AMediaCodec_createDecoderByType("video/avc");
  if (codec == NULL) {
    set_last_error(s, "No H.264 (video/avc) decoder available");
    return 0;
  }
  AMediaFormat *format = AMediaFormat_new();
  AMediaFormat_setString(format, AMEDIAFORMAT_KEY_MIME, "video/avc");
  AMediaFormat_setInt32(format, AMEDIAFORMAT_KEY_WIDTH, width);
  AMediaFormat_setInt32(format, AMEDIAFORMAT_KEY_HEIGHT, height);
  const int started =
      AMediaCodec_configure(codec, format, NULL, NULL, 0) == AMEDIA_OK &&
      AMediaCodec_start(codec) == AMEDIA_OK;
  AMediaFormat_delete(format);
  if (!started) {
    AMediaCodec_delete(codec);
    set_last_error(s, "Failed to start H.264 decoder for %dx%d", width, height);
    return 0;
  }
  s->h264.codec = codec;
  s->h264.configured_width = width;
  s->h264.configured_height = height;
  s->h264.awaiting_keyframe = 1;
  s->h264.out_color_format = H264_COLOR_FORMAT_NV12;
  s->h264.out_stride = width;
  s->h264.out_slice_height = height;
  s->h264.out_width = width;
  s->h264.out_height = height;
  return 1;
}

static void h264_read_output_format_locked(uvc_session_t *s) {
  AMediaFormat *format = AMediaCodec_getOutputFormat(s->h264.codec);
  if (format == NULL) {
    return;
  }
  int32_t value = 0;
  if (AMediaFormat_getInt32(format, AMEDIAFORMAT_KEY_COLOR_FORMAT, &value)) {
    s->h264.out_color_format = value;
  }
  if (AMediaFormat_getInt32(format, AMEDIAFORMAT_KEY_WIDTH, &value) &&
      value > 0) {
    s->h264.out_width = value;
  }
  if (AMediaFormat_getInt32(format, AMEDIAFORMAT_KEY_HEIGHT, &value) &&
      value > 0) {
    s->h264.out_height = value;
  }
  s->h264.out_stride = s->h264.out_width;
  if (AMediaFormat_getInt32(format, "stride", &value) && value > 0) {
    s->h264.out_stride = value;
  }
  s->h264.out_slice_height = s->h264.out_height;
  if (AMediaFormat_getInt32(format, "slice-height", &value) && value > 0) {
    s->h264.out_slice_height = value;
  }
  // The crop rect trims decoder padding. Decoders emit a 0,0 origin in
  // practice, so only the extents are honored.
  int32_t left = 0, top = 0, right = -1, bottom = -1;
  if (AMediaFormat_getInt32(format, "crop-left", &left) &&
      AMediaFormat_getInt32(format, "crop-top", &top) &&
      AMediaFormat_getInt32(format, "crop-right", &right) &&
      AMediaFormat_getInt32(format, "crop-bottom", &bottom) &&
      right >= left && bottom >= top) {
    s->h264.out_width = right - left + 1;
    s->h264.out_height = bottom - top + 1;
  }
  AMediaFormat_delete(format);
}

#if defined(__aarch64__)
// Converts 8 pixels (y offset by -16, chroma by -128, one chroma value per
// pixel) with the same BT.601 integer math as the scalar loop. Products are
// accumulated in 32 bits because 298 * y exceeds int16 range.
static inline void h264_yuv8_to_rgba_neon(int16x8_t y, int16x8_t u,
                                          int16x8_t v, uint8_t *dst) {
  const int32x4_t bias = vdupq_n_s32(128);
  const int16x4_t y_lo = vget_low_s16(y);
  const int16x4_t y_hi = vget_high_s16(y);
  const int16x4_t u_lo = vget_low_s16(u);
  const int16x4_t u_hi = vget_high_s16(u);
  const int16x4_t v_lo = vget_low_s16(v);
  const int16x4_t v_hi = vget_high_s16(v);
  const int32x4_t y298_lo = vmlal_n_s16(bias, y_lo, 298);
  const int32x4_t y298_hi = vmlal_n_s16(bias, y_hi, 298);
  const int32x4_t r_lo = vmlal_n_s16(y298_lo, v_lo, 409);
  const int32x4_t r_hi = vmlal_n_s16(y298_hi, v_hi, 409);
  const int32x4_t g_lo =
      vmlsl_n_s16(vmlsl_n_s16(y298_lo, u_lo, 100), v_lo, 208);
  const int32x4_t g_hi =
      vmlsl_n_s16(vmlsl_n_s16(y298_hi, u_hi, 100), v_hi, 208);
  const int32x4_t b_lo = vmlal_n_s16(y298_lo, u_lo, 516);
  const int32x4_t b_hi = vmlal_n_s16(y298_hi, u_hi, 516);
  uint8x8x4_t rgba;
  rgba.val[0] = vqmovun_s16(vcombine_s16(vqmovn_s32(vshrq_n_s32(r_lo, 8)),
                                         vqmovn_s32(vshrq_n_s32(r_hi, 8))));
  rgba.val[1] = vqmovun_s16(vcombine_s16(vqmovn_s32(vshrq_n_s32(g_lo, 8)),
                                         vqmovn_s32(vshrq_n_s32(g_hi, 8))));
  rgba.val[2] = vqmovun_s16(vcombine_s16(vqmovn_s32(vshrq_n_s32(b_lo, 8)),
                                         vqmovn_s32(vshrq_n_s32(b_hi, 8))));
  rgba.val[3] = vdup_n_u8(0xFF);
  vst4_u8(dst, rgba);
}
#endif

// BT.601 limited-range YUV420 (NV12 semi-planar or I420 planar) -> RGBA
// straight into latest_rgba, bypassing the RGB24 intermediate used by
// uvc_any2rgb-based formats.
static int h264_output_to_latest_rgba_locked(uvc_session_t *s, const uint8_t *buf,
                                             size_t buf_len) {
  const int w = s->h264.out_width;
  const int h = s->h264.out_height;
  const int stride = s->h264.out_stride;
  const int slice = s->h264.out_slice_height;
  if (w <= 0 || h <= 0 || stride < w || slice < h) {
    set_last_error(s,
        "H.264 decoder reported invalid output layout %dx%d stride=%d slice=%d",
        w, h, stride, slice);
    return 0;
  }
  const size_t luma_bytes = (size_t)stride * (size_t)slice;
  const size_t required = luma_bytes + (size_t)stride * (size_t)(h / 2);
  if (buf_len < required) {
    set_last_error(s, "H.264 decoder output too small: %zu < %zu", buf_len,
                   required);
    return 0;
  }

  const size_t rgba_bytes = (size_t)w * (size_t)h * 4;
  if (s->latest_rgba_bytes != rgba_bytes) {
    uint8_t *new_buffer = realloc(s->latest_rgba, rgba_bytes);
    if (new_buffer == NULL) {
      s->stats.buffer_allocation_failure_count += 1;
      set_last_error(s, "Failed to allocate %zu bytes for preview frame",
                     rgba_bytes);
      return 0;
    }
    s->latest_rgba = new_buffer;
    s->latest_rgba_bytes = rgba_bytes;
  }

  const int nv12 = s->h264.out_color_format != H264_COLOR_FORMAT_I420;
  const uint8_t *y_plane = buf;
  const uint8_t *chroma = buf + luma_bytes;
  const size_t c_stride = (size_t)stride / 2;
  const uint8_t *u_plane = chroma;
  const uint8_t *v_plane = chroma + c_stride * (size_t)(slice / 2);

  for (int row = 0; row < h; ++row) {
    const uint8_t *y_row = y_plane + (size_t)row * (size_t)stride;
    uint8_t *dst = s->latest_rgba + (size_t)row * (size_t)w * 4u;
    const uint8_t *uv_row = chroma + (size_t)(row / 2) * (size_t)stride;
    const uint8_t *u_row = u_plane + (size_t)(row / 2) * c_stride;
    const uint8_t *v_row = v_plane + (size_t)(row / 2) * c_stride;
    int col = 0;
#if defined(__aarch64__)
    const int16x8_t c16 = vdupq_n_s16(16);
    const int16x8_t c128 = vdupq_n_s16(128);
    for (; col + 16 <= w; col += 16) {
      const uint8x16_t y_u8 = vld1q_u8(y_row + col);
      const int16x8_t y_lo = vsubq_s16(
          vreinterpretq_s16_u16(vmovl_u8(vget_low_u8(y_u8))), c16);
      const int16x8_t y_hi = vsubq_s16(
          vreinterpretq_s16_u16(vmovl_u8(vget_high_u8(y_u8))), c16);
      int16x8_t u8s, v8s;
      if (nv12) {
        const uint8x8x2_t uv = vld2_u8(uv_row + col);
        u8s = vsubq_s16(vreinterpretq_s16_u16(vmovl_u8(uv.val[0])), c128);
        v8s = vsubq_s16(vreinterpretq_s16_u16(vmovl_u8(uv.val[1])), c128);
      } else {
        u8s = vsubq_s16(
            vreinterpretq_s16_u16(vmovl_u8(vld1_u8(u_row + col / 2))), c128);
        v8s = vsubq_s16(
            vreinterpretq_s16_u16(vmovl_u8(vld1_u8(v_row + col / 2))), c128);
      }
      // Zipping a vector with itself repeats each 4:2:0 chroma sample for
      // its two pixels.
      const int16x8x2_t u_zip = vzipq_s16(u8s, u8s);
      const int16x8x2_t v_zip = vzipq_s16(v8s, v8s);
      h264_yuv8_to_rgba_neon(y_lo, u_zip.val[0], v_zip.val[0],
                             dst + (size_t)col * 4u);
      h264_yuv8_to_rgba_neon(y_hi, u_zip.val[1], v_zip.val[1],
                             dst + (size_t)(col + 8) * 4u);
    }
#endif
    for (; col < w; ++col) {
      const int y = (int)y_row[col] - 16;
      int u, v;
      if (nv12) {
        u = (int)uv_row[col & ~1] - 128;
        v = (int)uv_row[(col & ~1) + 1] - 128;
      } else {
        u = (int)u_row[col / 2] - 128;
        v = (int)v_row[col / 2] - 128;
      }
      int r = (298 * y + 409 * v + 128) >> 8;
      int g = (298 * y - 100 * u - 208 * v + 128) >> 8;
      int b = (298 * y + 516 * u + 128) >> 8;
      if (r < 0) r = 0; else if (r > 255) r = 255;
      if (g < 0) g = 0; else if (g > 255) g = 255;
      if (b < 0) b = 0; else if (b > 255) b = 255;
      dst[col * 4 + 0] = (uint8_t)r;
      dst[col * 4 + 1] = (uint8_t)g;
      dst[col * 4 + 2] = (uint8_t)b;
      dst[col * 4 + 3] = 0xFF;
    }
  }

  s->frame_width = w;
  s->frame_height = h;
  s->latest_sequence += 1;
  return 1;
}

// Feeds one H.264 access unit to the decoder and converts decoded output
// into latest_rgba. Every access unit must reach the decoder — a skipped
// one breaks the prediction chain and smears the picture — so the expensive
// display conversion self-paces and is skipped under load, never the input.
// Returns 1 when a frame was delivered, 0 when the input was consumed
// without display output (keyframe gating, decoder latency, paced-out
// conversion), -1 on a decode error (last_error set, decode_failure
// counted).
static int h264_process_frame_locked(uvc_session_t *s, const uvc_frame_t *frame) {
  const uint64_t now_ns = monotonic_time_ns();

  if (frame->data_bytes < 4) {
    s->stats.undersized_frame_count += 1;
    return 0;
  }
  if (!h264_decoder_ensure_locked(s, (int)frame->width, (int)frame->height)) {
    s->stats.decode_failure_count += 1;
    return -1;
  }

  // Drain the output side FIRST: released output buffers are what keeps the
  // decoder's input side from starving. Only the newest ready output is kept
  // for display; older ones are released undisplayed.
  ssize_t kept_idx = -1;
  AMediaCodecBufferInfo kept_info;
  memset(&kept_info, 0, sizeof(kept_info));
  while (1) {
    AMediaCodecBufferInfo info;
    const ssize_t out_idx =
        AMediaCodec_dequeueOutputBuffer(s->h264.codec, &info, 0);
    if (out_idx == AMEDIACODEC_INFO_OUTPUT_FORMAT_CHANGED) {
      h264_read_output_format_locked(s);
      continue;
    }
    if (out_idx == AMEDIACODEC_INFO_OUTPUT_BUFFERS_CHANGED) {
      continue;
    }
    if (out_idx < 0) {
      break;  // AMEDIACODEC_INFO_TRY_AGAIN_LATER or unknown: drained.
    }
    if (kept_idx >= 0) {
      AMediaCodec_releaseOutputBuffer(s->h264.codec, kept_idx, false);
      s->h264.display_skip_count += 1;
    }
    kept_idx = out_idx;
    kept_info = info;
  }

  int delivered = 0;
  int conversion_failed = 0;
  if (kept_idx >= 0) {
    // Pace conversions to at most two thirds of the callback time (with a
    // floor so the preview never fully stalls); a conversion slower than
    // the frame interval would otherwise consume the whole callback budget
    // and starve the decoder input.
    const int convert_due =
        !s->h264.awaiting_keyframe &&
        (s->h264.last_convert_start_ns == 0 ||
         now_ns - s->h264.last_convert_start_ns >=
             (s->h264.last_convert_duration_ns * 3u) / 2u ||
         now_ns - s->h264.last_convert_start_ns >= 200000000ull);
    if (convert_due) {
      size_t out_capacity = 0;
      uint8_t *out = AMediaCodec_getOutputBuffer(s->h264.codec, kept_idx,
                                                 &out_capacity);
      if (out != NULL && kept_info.size > 0) {
        s->h264.last_convert_start_ns = now_ns;
        if (h264_output_to_latest_rgba_locked(s, out + kept_info.offset,
                                              (size_t)kept_info.size)) {
          delivered = 1;
        } else {
          conversion_failed = 1;
          s->stats.conversion_failure_count += 1;
          s->stats.decode_failure_count += 1;
        }
        s->h264.last_convert_duration_ns =
            monotonic_time_ns() - s->h264.last_convert_start_ns;
      }
    } else {
      s->h264.display_skip_count += 1;
    }
    AMediaCodec_releaseOutputBuffer(s->h264.codec, kept_idx, false);
  }

  // Source-sequence continuity: a gap means an access unit was lost in
  // transport and every following P-frame would smear until the next
  // keyframe. When the camera accepts sync-frame requests, freeze on the
  // last good frame and ask for an IDR instead; without that capability the
  // freeze could last a whole GOP, so decoding continues (and smears).
  if (s->h264.has_last_au_sequence &&
      frame->sequence != s->h264.last_au_sequence + 1 &&
      s->h264.eu_unit_id != 0 && !s->h264.awaiting_keyframe) {
    s->h264.awaiting_keyframe = 1;
  }
  s->h264.last_au_sequence = frame->sequence;
  s->h264.has_last_au_sequence = 1;

  // A payload that does not begin with an Annex-B start code lost its head in
  // transport; never feed it to the decoder.
  const uint8_t *payload = (const uint8_t *)frame->data;
  const int has_start_code =
      payload[0] == 0 && payload[1] == 0 &&
      (payload[2] == 1 || (payload[2] == 0 && payload[3] == 1));
  if (!has_start_code) {
    s->stats.decode_failure_count += 1;
    if (s->h264.eu_unit_id != 0) {
      s->h264.awaiting_keyframe = 1;
      h264_mark_keyframe_request_locked(s, now_ns,
                                        H264_IDR_REQUEST_MIN_INTERVAL_NS);
    }
    return delivered;
  }

  if (s->h264.awaiting_keyframe) {
    if (!h264_contains_idr(payload, frame->data_bytes)) {
      s->stats.warmup_drop_count += 1;
      h264_mark_keyframe_request_locked(s, now_ns,
                                        H264_IDR_REQUEST_MIN_INTERVAL_NS);
      return delivered;
    }
    s->h264.awaiting_keyframe = 0;
  } else {
    // Reference corruption without a decoder error is undetectable; a
    // periodic sync-frame request bounds how long it can smear.
    h264_mark_keyframe_request_locked(s, now_ns, H264_PERIODIC_IDR_INTERVAL_NS);
  }

  // Submit the access unit. The output drain above usually freed an input
  // buffer already; the blocking retry is the last resort before the chain
  // has to break.
  ssize_t in_idx = AMediaCodec_dequeueInputBuffer(s->h264.codec, 0);
  if (in_idx < 0) {
    in_idx = AMediaCodec_dequeueInputBuffer(s->h264.codec, 10000);
  }
  if (in_idx < 0) {
    s->h264.input_skip_count += 1;
    if (s->h264.input_skip_count == 1 || s->h264.input_skip_count % 30 == 0) {
      UVC_LOGW(
          "UVC_NATIVE",
          "H264 decoder input starved; dropped AU (total=%" PRIu64 ")",
          s->h264.input_skip_count);
    }
    if (s->h264.eu_unit_id != 0) {
      s->h264.awaiting_keyframe = 1;
      h264_mark_keyframe_request_locked(s, now_ns,
                                        H264_IDR_REQUEST_MIN_INTERVAL_NS);
    }
    return delivered;
  }

  size_t capacity = 0;
  uint8_t *input = AMediaCodec_getInputBuffer(s->h264.codec, in_idx, &capacity);
  if (input == NULL || capacity < frame->data_bytes) {
    AMediaCodec_queueInputBuffer(s->h264.codec, in_idx, 0, 0, 0, 0);
    s->stats.decode_failure_count += 1;
    set_last_error(s, "H.264 input buffer too small (%zu < %zu)", capacity,
                   frame->data_bytes);
    return delivered ? 1 : -1;
  }
  memcpy(input, frame->data, frame->data_bytes);
  const uint64_t pts_us = now_ns / 1000u;
  if (AMediaCodec_queueInputBuffer(s->h264.codec, in_idx, 0, frame->data_bytes,
                                   pts_us, 0) != AMEDIA_OK) {
    s->h264.error_streak += 1;
    s->stats.decode_failure_count += 1;
    set_last_error(s, "H.264 decoder rejected input");
    // A persistently failing decoder is torn down; the next frame recreates
    // it and waits for a fresh keyframe.
    if (s->h264.error_streak >= 3) {
      h264_decoder_release_locked(s);
    }
    h264_mark_keyframe_request_locked(s, now_ns,
                                      H264_IDR_REQUEST_MIN_INTERVAL_NS);
    return delivered ? 1 : -1;
  }
  s->h264.error_streak = 0;

  if (!delivered && conversion_failed) {
    return -1;
  }
  return delivered;
}

#endif  // defined(__ANDROID__)

// Shared bookkeeping once latest_rgba holds a new frame: preview surface
// render, delivery stats, recording wake-up. Returns the delivered sequence;
// the caller runs dispatch_frame after releasing the mutex.
static int64_t finish_frame_delivery_locked(uvc_session_t *s,
    uint64_t callback_monotonic_ns) {
#if defined(__ANDROID__)
  render_latest_rgba_to_preview_surface_locked(s);
#endif
  if (s->stats.start_monotonic_ns != 0) {
    if (s->stats.delivered_frame_count == 0) {
      s->stats.first_frame_latency_ns =
          callback_monotonic_ns - s->stats.start_monotonic_ns;
    } else if (s->stats.last_delivered_monotonic_ns != 0 &&
               callback_monotonic_ns >= s->stats.last_delivered_monotonic_ns) {
      const uint64_t gap_ns =
          callback_monotonic_ns - s->stats.last_delivered_monotonic_ns;
      s->stats.delivered_gap_sum_ns += gap_ns;
      if (gap_ns > s->stats.delivered_gap_max_ns) {
        s->stats.delivered_gap_max_ns = gap_ns;
      }
      s->stats.gap_ring[s->stats.gap_ring_next] = gap_ns;
      s->stats.gap_ring_next =
          (s->stats.gap_ring_next + 1u) % 256u;
      if (s->stats.gap_ring_count < 256u) {
        s->stats.gap_ring_count += 1u;
      }
    }
  }
  s->stats.last_delivered_monotonic_ns = callback_monotonic_ns;
  s->stats.delivered_frame_count += 1;
  s->stats.decode_success_count += 1;
  if (s->recording_active) {
    pthread_cond_broadcast(&s->recording_cond);
  }
  clear_last_error(s);
  return s->latest_sequence;
}

static void frame_callback(uvc_frame_t *frame, void *user_ptr) {
  uvc_session_t *s = (uvc_session_t *)user_ptr;
  const uint64_t callback_monotonic_ns = monotonic_time_ns();

  if (frame == NULL || frame->data == NULL) {
    UVC_LOGW("UVC_NATIVE", "frame callback received null frame");
    return;
  }

  if (pthread_mutex_trylock(&s->mutex) != 0) {
    __sync_add_and_fetch(&s->stats.input_frame_count, 1);
    __sync_add_and_fetch(&s->stats.callback_lock_drop_count, 1);
    UVC_LOGT(
        "UVC_NATIVE",
        "dropping frame callback because previous callback is still processing");
    return;
  }
  if (!s->previewing || s->stopping_preview || s->rgb_frame == NULL) {
    pthread_mutex_unlock(&s->mutex);
    UVC_LOGW("UVC_NATIVE", "frame callback skipped because preview is stopping or rgb_frame is null");
    return;
  }
  s->callbacks_inflight += 1;
  s->callback_count += 1;
  s->stats.input_frame_count += 1;
  uint32_t callback_count = s->callback_count;

  if (s->stats.has_last_source_sequence &&
      frame->sequence <= s->stats.last_source_sequence) {
    s->stats.stale_frame_count += 1;
  }
  s->stats.last_source_sequence = frame->sequence;
  s->stats.has_last_source_sequence = 1;

  if (callback_count <= 5 || callback_count % 30 == 0) {
    UVC_LOGT(
        "UVC_NATIVE",
        "frame callback #%u format=%d width=%u height=%u bytes=%zu sequence=%u",
        callback_count,
        frame->frame_format,
        frame->width,
        frame->height,
        frame->data_bytes,
        frame->sequence);
  }

  const size_t expected_input_bytes = expected_frame_bytes_for_format(frame);
  if (expected_input_bytes > 0 && frame->data_bytes < expected_input_bytes) {
    s->stats.undersized_frame_count += 1;
    s->stats.decode_failure_count += 1;
    set_last_error(s,
        "Frame too small for format=%s width=%u height=%u expected>=%zu actual=%zu",
        frame_format_name(frame->frame_format),
        frame->width,
        frame->height,
        expected_input_bytes,
        frame->data_bytes);
    UVC_LOGW(
        "UVC_NATIVE",
        "rejecting undersized frame callback=%u format=%d width=%u height=%u expected>=%zu actual=%zu",
        callback_count,
        frame->frame_format,
        frame->width,
        frame->height,
        expected_input_bytes,
        frame->data_bytes);
    const char *error_message = stage_error_ring_locked(s);
    finish_callback_locked(s);
    pthread_mutex_unlock(&s->mutex);
    dispatch_error(s, error_message);
    return;
  }

  if (frame->frame_format == UVC_FRAME_FORMAT_MJPEG) {
    uint32_t warmup_drop_remaining = s->mjpeg_warmup_drop_remaining;
    if (warmup_drop_remaining > 0) {
      s->mjpeg_warmup_drop_remaining -= 1;
    }

    if (warmup_drop_remaining > 0) {
      UVC_LOGT(
          "UVC_NATIVE",
          "dropping MJPEG warmup frame callback=%u remaining=%u bytes=%zu",
          callback_count,
          warmup_drop_remaining - 1,
          frame->data_bytes);
      s->stats.warmup_drop_count += 1;
      finish_callback_locked(s);
      pthread_mutex_unlock(&s->mutex);
      return;
    }

    if (!has_mjpeg_soi_marker(frame)) {
      s->stats.invalid_mjpeg_count += 1;
      s->stats.decode_failure_count += 1;
      set_last_error(s,
          "Invalid MJPEG frame missing SOI marker width=%u height=%u bytes=%zu",
          frame->width,
          frame->height,
          frame->data_bytes);
      UVC_LOGW(
          "UVC_NATIVE",
          "rejecting MJPEG frame missing SOI marker callback=%u width=%u height=%u bytes=%zu",
          callback_count,
          frame->width,
          frame->height,
          frame->data_bytes);
      const char *error_message = stage_error_ring_locked(s);
      finish_callback_locked(s);
      pthread_mutex_unlock(&s->mutex);
      dispatch_error(s, error_message);
      return;
    }
  }

#if defined(__ANDROID__)
  if (frame->frame_format == UVC_FRAME_FORMAT_H264) {
    const int h264_result = h264_process_frame_locked(s, frame);
    // The EU control transfer runs after unlock so a slow USB round-trip
    // never blocks API calls contending for the mutex. The stream callback
    // thread outlives this call, so devh stays valid.
    uvc_device_handle_t *keyframe_devh = NULL;
    const uint8_t keyframe_eu_unit_id = s->h264.eu_unit_id;
    if (s->h264.keyframe_request_due) {
      s->h264.keyframe_request_due = 0;
      keyframe_devh = s->devh;
    }
    if (h264_result <= 0) {
      if (h264_result < 0) {
        const char *error_message = stage_error_ring_locked(s);
        finish_callback_locked(s);
        pthread_mutex_unlock(&s->mutex);
        if (keyframe_devh != NULL) {
          h264_request_keyframe(keyframe_devh, keyframe_eu_unit_id);
        }
        dispatch_error(s, error_message);
        return;
      }
      finish_callback_locked(s);
      pthread_mutex_unlock(&s->mutex);
      if (keyframe_devh != NULL) {
        h264_request_keyframe(keyframe_devh, keyframe_eu_unit_id);
      }
      return;
    }
    const int64_t h264_sequence =
        finish_frame_delivery_locked(s, callback_monotonic_ns);
    finish_callback_locked(s);
    pthread_mutex_unlock(&s->mutex);
    if (keyframe_devh != NULL) {
      h264_request_keyframe(keyframe_devh, keyframe_eu_unit_id);
    }
    dispatch_frame(s, h264_sequence);
    return;
  }
#endif  // defined(__ANDROID__)

  const size_t required_rgb_bytes = (size_t)frame->width * (size_t)frame->height * 3;

  if (!ensure_rgb_frame_locked(s, required_rgb_bytes)) {
    UVC_LOGE(
        "UVC_NATIVE",
        "frame callback failed to prepare rgb buffer callback=%u width=%u height=%u bytes=%zu",
        callback_count,
        frame->width,
        frame->height,
        required_rgb_bytes);
    const char *error_message = stage_error_ring_locked(s);
    finish_callback_locked(s);
    pthread_mutex_unlock(&s->mutex);
    dispatch_error(s, error_message);
    return;
  }

  uvc_error_t convert_result = uvc_any2rgb(frame, s->rgb_frame);
  if (convert_result != UVC_SUCCESS) {
    s->stats.conversion_failure_count += 1;
    s->stats.decode_failure_count += 1;
    set_last_error(s, "uvc_any2rgb failed: %s", uvc_strerror(convert_result));
    UVC_LOGE(
        "UVC_NATIVE",
        "uvc_any2rgb failed callback=%u format=%d width=%u height=%u err=%s",
        callback_count,
        frame->frame_format,
        frame->width,
        frame->height,
        uvc_strerror(convert_result));
    const char *error_message = stage_error_ring_locked(s);
    finish_callback_locked(s);
    pthread_mutex_unlock(&s->mutex);
    dispatch_error(s, error_message);
    return;
  }

  const size_t rgba_bytes = (size_t)s->rgb_frame->width * (size_t)s->rgb_frame->height * 4;
  int64_t delivered_sequence = 0;

  if (!update_latest_rgba_locked(s)) {
    const char *error_message = stage_error_ring_locked(s);
    finish_callback_locked(s);
    pthread_mutex_unlock(&s->mutex);
    dispatch_error(s, error_message);
    return;
  }
  delivered_sequence = finish_frame_delivery_locked(s, callback_monotonic_ns);
  const int delivered_width = s->frame_width;
  const int delivered_height = s->frame_height;
  finish_callback_locked(s);
  pthread_mutex_unlock(&s->mutex);

  if (callback_count <= 5 || callback_count % 30 == 0) {
    UVC_LOGT(
        "UVC_NATIVE",
        "frame callback #%u converted rgb width=%d height=%d rgbaBytes=%zu",
        callback_count,
        delivered_width,
        delivered_height,
        rgba_bytes);
  }

  dispatch_frame(s, delivered_sequence);
}

// ---------------------------------------------------------------------------
// Session lifecycle
// ---------------------------------------------------------------------------

FFI_PLUGIN_EXPORT uvc_session_t *uvc_session_create(void) {
  uvc_session_t *s = calloc(1, sizeof(*s));
  if (s == NULL) {
    return NULL;
  }
  pthread_mutex_init(&s->mutex, NULL);
  pthread_mutex_init(&s->usb_mutex, NULL);
  pthread_mutex_init(&s->error_mutex, NULL);
  pthread_mutex_init(&s->listener_mutex, NULL);
  pthread_cond_init(&s->callback_cond, NULL);
  pthread_cond_init(&s->recording_cond, NULL);
#if defined(__ANDROID__)
  s->rec.fd = -1;
  s->rec.video_track = -1;
#endif
  registry_add(s);
  UVC_LOGD("UVC_NATIVE", "uvc_session_create session=%p", (void *)s);
  return s;
}

FFI_PLUGIN_EXPORT void uvc_session_destroy(uvc_session_t *session) {
  if (session == NULL || !registry_retire(session)) {
    return;
  }
  UVC_LOGD("UVC_NATIVE", "uvc_session_destroy session=%p", (void *)session);
  // Stops recording and preview, closes the device, releases the preview
  // window, and frees the frame buffers. No callback or listener runs afterwards.
  uvc_close_device(session);
  pthread_mutex_lock(&session->listener_mutex);
  session->frame_listener = NULL;
  session->frame_listener_user_data = NULL;
  session->error_listener = NULL;
  session->error_listener_user_data = NULL;
  pthread_mutex_unlock(&session->listener_mutex);
  pthread_cond_destroy(&session->recording_cond);
  pthread_cond_destroy(&session->callback_cond);
  pthread_mutex_destroy(&session->listener_mutex);
  pthread_mutex_destroy(&session->error_mutex);
  pthread_mutex_destroy(&session->usb_mutex);
  pthread_mutex_destroy(&session->mutex);
  free(session);
}

FFI_PLUGIN_EXPORT int uvc_open_fd(uvc_session_t *s, int fd) {
  if (s == NULL) {
    return UVC_ERROR_INVALID_PARAM;
  }
  if (fd < 0) {
    set_last_error(s, "Invalid file descriptor: %d", fd);
    return UVC_ERROR_INVALID_PARAM;
  }

  uvc_stop_recording(s);

  uvc_device_handle_t *devh_to_stop = NULL;
  int should_stop_streaming = 0;

  pthread_mutex_lock(&s->mutex);
  should_stop_streaming = begin_stop_preview_locked(s, &devh_to_stop);
  if (should_stop_streaming) {
    pthread_mutex_lock(&s->usb_mutex);
  }
  pthread_mutex_unlock(&s->mutex);

  if (should_stop_streaming) {
    uvc_stop_streaming(devh_to_stop);
    pthread_mutex_unlock(&s->usb_mutex);
  }

  pthread_mutex_lock(&s->mutex);
  pthread_mutex_lock(&s->usb_mutex);
  if (should_stop_streaming) {
    finish_stop_preview_locked(s);
  }
  close_device_resources_locked(s);
  clear_last_error(s);

  uvc_error_t result = uvc_init(&s->ctx, NULL);
  if (result != UVC_SUCCESS) {
    set_last_error(s, "uvc_init failed: %s", uvc_strerror(result));
    close_device_resources_locked(s);
    pthread_mutex_unlock(&s->usb_mutex);
    pthread_mutex_unlock(&s->mutex);
    return result;
  }

  result = uvc_wrap(fd, s->ctx, &s->devh);
  if (result != UVC_SUCCESS) {
    set_last_error(s, "uvc_wrap failed: %s", uvc_strerror(result));
    close_device_resources_locked(s);
    pthread_mutex_unlock(&s->usb_mutex);
    pthread_mutex_unlock(&s->mutex);
    return result;
  }

  UVC_LOGI("UVC_NATIVE", "uvc_open_fd success fd=%d", fd);
  uvc_device_t *device = uvc_get_device(s->devh);
  if (device != NULL) {
    uvc_device_descriptor_t *descriptor = NULL;
    uvc_error_t descriptor_result = uvc_get_device_descriptor(device, &descriptor);
    if (descriptor_result == UVC_SUCCESS && descriptor != NULL) {
      UVC_LOGD(
          "UVC_NATIVE",
          "device descriptor vendor=%04x product=%04x manufacturer=%s productName=%s serial=%s",
          descriptor->idVendor,
          descriptor->idProduct,
          descriptor->manufacturer ? descriptor->manufacturer : "(null)",
          descriptor->product ? descriptor->product : "(null)",
          descriptor->serialNumber ? descriptor->serialNumber : "(null)");
      uvc_free_device_descriptor(descriptor);
    } else {
      UVC_LOGD("UVC_NATIVE", "uvc_get_device_descriptor failed err=%s", uvc_strerror(descriptor_result));
    }
  } else {
    UVC_LOGW("UVC_NATIVE", "uvc_get_device returned null");
  }

  UVC_LOGD(
      "UVC_NATIVE",
      "camera terminal=%p input terminals=%p processing units=%p extension units=%p",
      (void *)uvc_get_camera_terminal(s->devh),
      (void *)uvc_get_input_terminals(s->devh),
      (void *)uvc_get_processing_units(s->devh),
      (void *)uvc_get_extension_units(s->devh));

  s->rgb_frame = uvc_allocate_frame(1);
  if (s->rgb_frame == NULL) {
    set_last_error(s, "Failed to allocate RGB frame buffer");
    close_device_resources_locked(s);
    pthread_mutex_unlock(&s->usb_mutex);
    pthread_mutex_unlock(&s->mutex);
    return UVC_ERROR_NO_MEM;
  }

  pthread_mutex_unlock(&s->usb_mutex);
  pthread_mutex_unlock(&s->mutex);
  return UVC_SUCCESS;
}

FFI_PLUGIN_EXPORT int uvc_start_preview(
    uvc_session_t *s,
    int frame_format,
    int width,
    int height,
    int fps) {
  uvc_device_handle_t *devh_to_stop = NULL;
  int should_stop_streaming = 0;

  if (s == NULL) {
    return UVC_ERROR_INVALID_PARAM;
  }

#if !defined(__ANDROID__)
  // The AMediaCodec decode path only exists in the Android build.
  if (frame_format == UVC_FRAME_FORMAT_H264) {
    set_last_error(s, "H.264 preview requires the Android backend");
    return UVC_ERROR_NOT_SUPPORTED;
  }
#endif

  uvc_stop_recording(s);

  pthread_mutex_lock(&s->mutex);

  if (s->devh == NULL) {
    set_last_error(s, "Camera is not open");
    pthread_mutex_unlock(&s->mutex);
    return UVC_ERROR_NO_DEVICE;
  }

  should_stop_streaming = begin_stop_preview_locked(s, &devh_to_stop);
  if (should_stop_streaming) {
    pthread_mutex_lock(&s->usb_mutex);
  }
  pthread_mutex_unlock(&s->mutex);

  if (should_stop_streaming) {
    uvc_stop_streaming(devh_to_stop);
    pthread_mutex_unlock(&s->usb_mutex);
  }

  pthread_mutex_lock(&s->mutex);
  if (should_stop_streaming) {
    finish_stop_preview_locked(s);
  }

  // The device may have been closed while the mutex was released above.
  if (s->devh == NULL) {
    set_last_error(s, "Camera is not open");
    pthread_mutex_unlock(&s->mutex);
    return UVC_ERROR_NO_DEVICE;
  }

  uvc_stream_ctrl_t ctrl;
  memset(&ctrl, 0, sizeof(ctrl));

  const size_t required_rgb_bytes = (size_t)width * (size_t)height * 3;
  if (!ensure_rgb_frame_locked(s, required_rgb_bytes)) {
    pthread_mutex_unlock(&s->mutex);
    return UVC_ERROR_NO_MEM;
  }

  pthread_mutex_lock(&s->usb_mutex);
  uvc_error_t result = uvc_get_stream_ctrl_format_size(
      s->devh,
      &ctrl,
      (enum uvc_frame_format)frame_format,
      width,
      height,
      fps);

  if (result != UVC_SUCCESS) {
    UVC_LOGW(
        "UVC_NATIVE",
        "uvc_get_stream_ctrl_format_size failed format=%d width=%d height=%d fps=%d err=%s",
        frame_format,
        width,
        height,
        fps,
        uvc_strerror(result));
    set_last_error(s, "uvc_get_stream_ctrl_format_size failed: %s", uvc_strerror(result));
    pthread_mutex_unlock(&s->usb_mutex);
    pthread_mutex_unlock(&s->mutex);
    return result;
  }

  result = uvc_start_streaming(s->devh, &ctrl, frame_callback, s, 0);
  if (result != UVC_SUCCESS) {
    UVC_LOGE("UVC_NATIVE", "uvc_start_streaming failed err=%s", uvc_strerror(result));
    set_last_error(s, "uvc_start_streaming failed: %s", uvc_strerror(result));
    pthread_mutex_unlock(&s->usb_mutex);
    pthread_mutex_unlock(&s->mutex);
    return result;
  }

  reset_stream_stats_locked(s);
  s->stats.start_monotonic_ns = monotonic_time_ns();
  s->previewing = 1;
  s->callback_count = 0;
  s->latest_sequence = 0;
  s->mjpeg_warmup_drop_remaining =
      frame_format == UVC_FRAME_FORMAT_MJPEG ? 3 : 0;
#if defined(__ANDROID__)
  uvc_device_handle_t *h264_keyframe_devh = NULL;
  uint8_t h264_keyframe_eu_unit_id = 0;
  if (frame_format == UVC_FRAME_FORMAT_H264) {
    // Probe the UVC 1.5 Encoding Unit once per session; with it, sync-frame
    // requests cut the initial keyframe wait and bound corruption recovery.
    s->h264.eu_unit_id = h264_find_encoding_unit(s->devh);
    UVC_LOGI(
        "UVC_NATIVE",
        "H264 encoding unit %s (id=%u)",
        s->h264.eu_unit_id != 0 ? "found" : "not present",
        s->h264.eu_unit_id);
    if (s->h264.eu_unit_id != 0) {
      s->h264.last_idr_request_ns = monotonic_time_ns();
      h264_keyframe_devh = s->devh;
      h264_keyframe_eu_unit_id = s->h264.eu_unit_id;
    }
  }
#endif
  clear_last_error(s);
  UVC_LOGI(
      "UVC_NATIVE",
      "uvc_start_preview success format=%d width=%d height=%d fps=%d",
      frame_format,
      width,
      height,
      fps);
  pthread_mutex_unlock(&s->mutex);
#if defined(__ANDROID__)
  // Still under usb_mutex so devh stays open, but no longer under the main
  // mutex so frames and API calls are not blocked.
  if (h264_keyframe_devh != NULL) {
    h264_request_keyframe(h264_keyframe_devh, h264_keyframe_eu_unit_id);
  }
#endif
  pthread_mutex_unlock(&s->usb_mutex);
  return UVC_SUCCESS;
}

// Writes the descriptor-reported modes as JSON.
static int write_modes_json_locked(uvc_session_t *s, uint8_t *buffer, int buffer_length) {
  char *json = (char *)buffer;
  size_t offset = 0;
  int first_mode = 1;
  const uvc_format_desc_t *format_desc = uvc_get_format_descs(s->devh);

  if (!append_json(json, (size_t)buffer_length, &offset, "[")) {
    return 0;
  }

  UVC_LOGD("UVC_NATIVE", "enumerating supported modes");
  if (format_desc == NULL) {
    UVC_LOGW("UVC_NATIVE", "uvc_get_format_descs returned null");
  }
  for (; format_desc != NULL; format_desc = format_desc->next) {
    enum uvc_frame_format frame_format = format_desc_to_frame_format(format_desc);
    char fourcc[5];
    format_fourcc_string(format_desc, fourcc, sizeof(fourcc));
    UVC_LOGD(
        "UVC_NATIVE",
        "format descriptor subtype=%d formatIndex=%u fourcc=%s parsedFormat=%d",
        format_desc->bDescriptorSubtype,
        format_desc->bFormatIndex,
        fourcc,
        frame_format);
    if (frame_format == UVC_FRAME_FORMAT_UNKNOWN) {
      UVC_LOGD("UVC_NATIVE", "skipping unsupported format descriptor");
      continue;
    }
#if !defined(__ANDROID__)
    // The AMediaCodec decode path only exists in the Android build, so H.264
    // modes would negotiate but never render; keep them out of the list like
    // the Windows backend does.
    if (frame_format == UVC_FRAME_FORMAT_H264) {
      UVC_LOGD("UVC_NATIVE", "skipping H264 format descriptor (no decoder in this build)");
      continue;
    }
#endif

    const uvc_frame_desc_t *frame_desc = format_desc->frame_descs;
    for (; frame_desc != NULL; frame_desc = frame_desc->next) {
      UVC_LOGT(
          "UVC_NATIVE",
          "frame descriptor frameIndex=%u width=%u height=%u intervalType=%u defaultInterval=%u",
          frame_desc->bFrameIndex,
          frame_desc->wWidth,
          frame_desc->wHeight,
          frame_desc->bFrameIntervalType,
          frame_desc->dwDefaultFrameInterval);
      if (frame_desc->intervals != NULL) {
        for (uint32_t *interval = frame_desc->intervals; *interval != 0; ++interval) {
          int fps = (int)(10000000u / *interval);
          UVC_LOGT("UVC_NATIVE", "mode format=%s width=%u height=%u fps=%d interval=%u", frame_format_name(frame_format), frame_desc->wWidth, frame_desc->wHeight, fps, *interval);
          if (!append_json(
                  json,
                  (size_t)buffer_length,
                  &offset,
                  "%s{\"format\":%d,\"formatName\":\"%s\",\"width\":%u,\"height\":%u,\"fps\":%d}",
                  first_mode ? "" : ",",
                  frame_format,
                  frame_format_name(frame_format),
                  frame_desc->wWidth,
                  frame_desc->wHeight,
                  fps)) {
            return 0;
          }
          first_mode = 0;
        }
      } else if (frame_desc->dwDefaultFrameInterval != 0) {
        int fps = (int)(10000000u / frame_desc->dwDefaultFrameInterval);
        UVC_LOGT("UVC_NATIVE", "mode(default) format=%s width=%u height=%u fps=%d interval=%u", frame_format_name(frame_format), frame_desc->wWidth, frame_desc->wHeight, fps, frame_desc->dwDefaultFrameInterval);
        if (!append_json(
                json,
                (size_t)buffer_length,
                &offset,
                "%s{\"format\":%d,\"formatName\":\"%s\",\"width\":%u,\"height\":%u,\"fps\":%d}",
                first_mode ? "" : ",",
                frame_format,
                frame_format_name(frame_format),
                frame_desc->wWidth,
                frame_desc->wHeight,
                fps)) {
          return 0;
        }
        first_mode = 0;
      }
    }
  }

  if (!append_json(json, (size_t)buffer_length, &offset, "]")) {
    return 0;
  }

  UVC_LOGD("UVC_NATIVE", "supported modes json bytes=%zu", offset);
  return (int)offset;
}

FFI_PLUGIN_EXPORT int uvc_get_supported_modes_json(uvc_session_t *s, uint8_t *buffer, int buffer_length) {
  if (s == NULL || buffer == NULL || buffer_length <= 0) {
    return 0;
  }

  pthread_mutex_lock(&s->mutex);
  if (s->devh == NULL) {
    UVC_LOGD("UVC_NATIVE", "uvc_get_supported_modes_json called without open device");
    pthread_mutex_unlock(&s->mutex);
    return 0;
  }
  const int written = write_modes_json_locked(s, buffer, buffer_length);
  pthread_mutex_unlock(&s->mutex);
  return written;
}

FFI_PLUGIN_EXPORT int64_t uvc_latest_frame_sequence(uvc_session_t *s) {
  if (s == NULL) {
    return UVC_ERROR_INVALID_PARAM;
  }
  pthread_mutex_lock(&s->mutex);
  const int64_t latest_sequence = s->latest_sequence;
  pthread_mutex_unlock(&s->mutex);
  return latest_sequence;
}

FFI_PLUGIN_EXPORT int uvc_get_stream_stats_json(uvc_session_t *s, uint8_t *buffer, int buffer_length) {
  if (s == NULL || buffer == NULL || buffer_length <= 0) {
    return 0;
  }

  pthread_mutex_lock(&s->mutex);
  const ffi_uvc_stream_stats_t stats = s->stats;
  const uint64_t now_ns = monotonic_time_ns();
  const uint64_t end_ns =
      stats.stop_monotonic_ns != 0 ? stats.stop_monotonic_ns : now_ns;
  const uint64_t elapsed_ns =
      (stats.start_monotonic_ns != 0 && end_ns >= stats.start_monotonic_ns)
          ? (end_ns - stats.start_monotonic_ns)
          : 0;
  pthread_mutex_unlock(&s->mutex);

  double input_fps = 0.0;
  double delivered_fps = 0.0;
  double avg_gap_ms = 0.0;
  double p95_gap_ms = 0.0;
  double max_gap_ms = (double)stats.delivered_gap_max_ns / 1000000.0;
  double first_frame_latency_ms =
      (double)stats.first_frame_latency_ns / 1000000.0;

  if (elapsed_ns > 0) {
    const double elapsed_seconds = (double)elapsed_ns / 1000000000.0;
    input_fps = (double)stats.input_frame_count / elapsed_seconds;
    delivered_fps = (double)stats.delivered_frame_count / elapsed_seconds;
  }

  if (stats.delivered_frame_count > 1) {
    avg_gap_ms =
        ((double)stats.delivered_gap_sum_ns /
            (double)(stats.delivered_frame_count - 1)) /
        1000000.0;
  }

  if (stats.gap_ring_count > 0) {
    uint64_t sorted_gaps[256];
    memcpy(sorted_gaps, stats.gap_ring, sizeof(uint64_t) * stats.gap_ring_count);
    qsort(sorted_gaps, stats.gap_ring_count, sizeof(uint64_t), compare_uint64_ascending);
    size_t p95_index = (size_t)(((stats.gap_ring_count - 1u) * 95u) / 100u);
    if (p95_index >= stats.gap_ring_count) {
      p95_index = stats.gap_ring_count - 1u;
    }
    p95_gap_ms = (double)sorted_gaps[p95_index] / 1000000.0;
  }

  char *json = (char *)buffer;
  size_t offset = 0;
  if (!append_json(
          json,
          (size_t)buffer_length,
          &offset,
          "{"
          "\"inputFrameCount\":%" PRIu64 ","
          "\"deliveredFrameCount\":%" PRIu64 ","
          "\"decodeSuccessCount\":%" PRIu64 ","
          "\"decodeFailureCount\":%" PRIu64 ","
          "\"callbackLockDropCount\":%" PRIu64 ","
          "\"warmupDropCount\":%" PRIu64 ","
          "\"staleFrameCount\":%" PRIu64 ","
          "\"undersizedFrameCount\":%" PRIu64 ","
          "\"invalidMjpegCount\":%" PRIu64 ","
          "\"bufferAllocationFailureCount\":%" PRIu64 ","
          "\"previewSurfaceFailureCount\":%" PRIu64 ","
          "\"conversionFailureCount\":%" PRIu64 ","
          "\"inputFps\":%.3f,"
          "\"deliveredFps\":%.3f,"
          "\"avgInterFrameGapMs\":%.3f,"
          "\"p95InterFrameGapMs\":%.3f,"
          "\"maxInterFrameGapMs\":%.3f,"
          "\"firstFrameLatencyMs\":%.3f,"
          "\"elapsedMs\":%.3f"
          "}",
          stats.input_frame_count,
          stats.delivered_frame_count,
          stats.decode_success_count,
          stats.decode_failure_count,
          stats.callback_lock_drop_count,
          stats.warmup_drop_count,
          stats.stale_frame_count,
          stats.undersized_frame_count,
          stats.invalid_mjpeg_count,
          stats.buffer_allocation_failure_count,
          stats.preview_surface_failure_count,
          stats.conversion_failure_count,
          input_fps,
          delivered_fps,
          avg_gap_ms,
          p95_gap_ms,
          max_gap_ms,
          first_frame_latency_ms,
          (double)elapsed_ns / 1000000.0)) {
    return 0;
  }

  return (int)offset;
}

FFI_PLUGIN_EXPORT void uvc_stop_preview(uvc_session_t *s) {
  uvc_device_handle_t *devh_to_stop = NULL;
  int should_stop_streaming = 0;

  if (s == NULL) {
    return;
  }

  UVC_LOGD("UVC_NATIVE", "uvc_stop_preview begin");
  uvc_stop_recording(s);
  pthread_mutex_lock(&s->mutex);
  UVC_LOGD(
      "UVC_NATIVE",
      "uvc_stop_preview locked previewing=%d devh=%p",
      s->previewing,
      (void *)s->devh);
  should_stop_streaming = begin_stop_preview_locked(s, &devh_to_stop);
  if (should_stop_streaming) {
    pthread_mutex_lock(&s->usb_mutex);
  }
  pthread_mutex_unlock(&s->mutex);

  if (should_stop_streaming) {
    UVC_LOGD("UVC_NATIVE", "uvc_stop_preview before uvc_stop_streaming");
    uvc_stop_streaming(devh_to_stop);
    UVC_LOGD("UVC_NATIVE", "uvc_stop_preview after uvc_stop_streaming");
    pthread_mutex_unlock(&s->usb_mutex);
  }

  pthread_mutex_lock(&s->mutex);
  if (s->stats.start_monotonic_ns != 0 &&
      s->stats.stop_monotonic_ns == 0) {
    s->stats.stop_monotonic_ns = monotonic_time_ns();
  }
  finish_stop_preview_locked(s);
  pthread_mutex_unlock(&s->mutex);
  UVC_LOGD("UVC_NATIVE", "uvc_stop_preview end");
}

FFI_PLUGIN_EXPORT void uvc_close_device(uvc_session_t *s) {
  uvc_device_handle_t *devh_to_stop = NULL;
  int should_stop_streaming = 0;

  if (s == NULL) {
    return;
  }

  uvc_stop_recording(s);
  pthread_mutex_lock(&s->mutex);
  UVC_LOGD(
      "UVC_NATIVE",
      "uvc_close_device begin previewing=%d devh=%p ctx=%p",
      s->previewing,
      (void *)s->devh,
      (void *)s->ctx);
  should_stop_streaming = begin_stop_preview_locked(s, &devh_to_stop);
  if (should_stop_streaming) {
    pthread_mutex_lock(&s->usb_mutex);
  }
  pthread_mutex_unlock(&s->mutex);

  if (should_stop_streaming) {
    uvc_stop_streaming(devh_to_stop);
    pthread_mutex_unlock(&s->usb_mutex);
  }

  pthread_mutex_lock(&s->mutex);
  pthread_mutex_lock(&s->usb_mutex);
  if (should_stop_streaming) {
    finish_stop_preview_locked(s);
  }
  close_device_resources_locked(s);
  UVC_LOGI("UVC_NATIVE", "uvc_close_device success");
  UVC_LOGD("UVC_NATIVE", "uvc_close_device end");
  pthread_mutex_unlock(&s->usb_mutex);
  pthread_mutex_unlock(&s->mutex);
}

FFI_PLUGIN_EXPORT int uvc_is_previewing(uvc_session_t *s) {
  if (s == NULL) {
    return UVC_ERROR_INVALID_PARAM;
  }
  pthread_mutex_lock(&s->mutex);
  int previewing = s->previewing;
  pthread_mutex_unlock(&s->mutex);
  return previewing;
}

#if defined(__ANDROID__)
// `session` is the registry id (uvc_session_id) as a jlong. 0 means no session.
JNIEXPORT jint JNICALL
Java_com_cornpip_flutter_1ffi_1uvc_FlutterFfiUvcPlugin_nativeAttachSurface(
    JNIEnv *env,
    jobject thiz,
    jlong session,
    jobject surface) {
  (void)thiz;
  // The Kotlin layer holds the id without owning the session. Pin it.
  uvc_session_t *s = uvc_session_acquire_id((uint64_t)session);
  if (surface == NULL || s == NULL) {
    if (s != NULL) uvc_session_release(s);
    return UVC_ERROR_INVALID_PARAM;
  }

  ANativeWindow *window = ANativeWindow_fromSurface(env, surface);
  if (window == NULL) {
    set_last_error(s, "Failed to acquire ANativeWindow from Surface");
    uvc_session_release(s);
    return UVC_ERROR_IO;
  }

  pthread_mutex_lock(&s->mutex);
  release_preview_window_locked(s);
  s->preview_window = window;
  pthread_mutex_unlock(&s->mutex);
  clear_last_error(s);
  uvc_session_release(s);
  return UVC_SUCCESS;
}

JNIEXPORT jboolean JNICALL
Java_com_cornpip_flutter_1ffi_1uvc_FlutterFfiUvcPlugin_nativeSessionIsLive(
    JNIEnv *env,
    jobject thiz,
    jlong session) {
  (void)env;
  (void)thiz;
  uvc_session_t *s = uvc_session_acquire_id((uint64_t)session);
  if (s == NULL) {
    return JNI_FALSE;
  }
  uvc_session_release(s);
  return JNI_TRUE;
}

// Closes the device of a live session. The Kotlin layer calls this before
// it closes the USB connection so libuvc never runs on a released fd.
JNIEXPORT void JNICALL
Java_com_cornpip_flutter_1ffi_1uvc_FlutterFfiUvcPlugin_nativeCloseDevice(
    JNIEnv *env,
    jobject thiz,
    jlong session) {
  (void)env;
  (void)thiz;
  uvc_session_t *s = uvc_session_acquire_id((uint64_t)session);
  if (s == NULL) {
    return;
  }
  uvc_close_device(s);
  uvc_session_release(s);
}

JNIEXPORT void JNICALL
Java_com_cornpip_flutter_1ffi_1uvc_FlutterFfiUvcPlugin_nativeDetachSurface(
    JNIEnv *env,
    jobject thiz,
    jlong session) {
  (void)env;
  (void)thiz;
  uvc_session_t *s = uvc_session_acquire_id((uint64_t)session);
  if (s == NULL) {
    return;
  }

  pthread_mutex_lock(&s->mutex);
  release_preview_window_locked(s);
  pthread_mutex_unlock(&s->mutex);
  uvc_session_release(s);
}
#endif

FFI_PLUGIN_EXPORT int uvc_frame_width(uvc_session_t *s) {
  if (s == NULL) {
    return UVC_ERROR_INVALID_PARAM;
  }
  pthread_mutex_lock(&s->mutex);
  int width = s->frame_width;
  pthread_mutex_unlock(&s->mutex);
  return width;
}

FFI_PLUGIN_EXPORT int uvc_frame_height(uvc_session_t *s) {
  if (s == NULL) {
    return UVC_ERROR_INVALID_PARAM;
  }
  pthread_mutex_lock(&s->mutex);
  int height = s->frame_height;
  pthread_mutex_unlock(&s->mutex);
  return height;
}

FFI_PLUGIN_EXPORT int uvc_copy_latest_frame_rgba(uvc_session_t *s, uint8_t *buffer, int buffer_length) {
  return uvc_copy_latest_frame_rgba_with_metadata(s, buffer, buffer_length, NULL, NULL, NULL);
}

FFI_PLUGIN_EXPORT int uvc_copy_latest_frame_rgba_with_metadata(
    uvc_session_t *s,
    uint8_t *buffer,
    int buffer_length,
    int *out_width,
    int *out_height,
    int64_t *out_sequence) {
  if (s == NULL) {
    return UVC_ERROR_INVALID_PARAM;
  }
  if (buffer == NULL || buffer_length <= 0) {
    return 0;
  }

  pthread_mutex_lock(&s->mutex);
  if (s->latest_rgba == NULL || s->latest_rgba_bytes == 0) {
    pthread_mutex_unlock(&s->mutex);
    return 0;
  }

  const int bytes_to_copy = s->latest_rgba_bytes < (size_t)buffer_length
      ? (int)s->latest_rgba_bytes
      : buffer_length;
  memcpy(buffer, s->latest_rgba, bytes_to_copy);
  if (out_width != NULL) {
    *out_width = s->frame_width;
  }
  if (out_height != NULL) {
    *out_height = s->frame_height;
  }
  if (out_sequence != NULL) {
    *out_sequence = s->latest_sequence;
  }
  pthread_mutex_unlock(&s->mutex);
  return bytes_to_copy;
}

FFI_PLUGIN_EXPORT int uvc_copy_latest_frame_rgba_transformed(
    uvc_session_t *s,
    uint8_t *buffer,
    int buffer_length,
    int rotation,
    int flip_h,
    int flip_v,
    int *out_width,
    int *out_height,
    int64_t *out_sequence) {
  if (s == NULL) {
    return UVC_ERROR_INVALID_PARAM;
  }
  if (buffer == NULL || buffer_length <= 0) {
    return 0;
  }

  int r = rotation % 360;
  if (r < 0) r += 360;
  if (r != 0 && r != 90 && r != 180 && r != 270) r = 0;
  const int fh = flip_h ? 1 : 0;
  const int fv = flip_v ? 1 : 0;

  pthread_mutex_lock(&s->mutex);
  if (s->latest_rgba == NULL || s->latest_rgba_bytes == 0) {
    pthread_mutex_unlock(&s->mutex);
    return 0;
  }

  const int src_w = s->frame_width;
  const int src_h = s->frame_height;
  const int dst_w = (r == 90 || r == 270) ? src_h : src_w;
  const int dst_h = (r == 90 || r == 270) ? src_w : src_h;
  const int expected_bytes = dst_w * dst_h * 4;

  if (buffer_length < expected_bytes) {
    pthread_mutex_unlock(&s->mutex);
    return 0;
  }

  blit_rgba_transform(
      (const uint32_t *)s->latest_rgba, src_w, src_h,
      (uint32_t *)buffer, dst_w,
      r, fh, fv);

  if (out_width != NULL)   *out_width   = dst_w;
  if (out_height != NULL)  *out_height  = dst_h;
  if (out_sequence != NULL) *out_sequence = s->latest_sequence;
  pthread_mutex_unlock(&s->mutex);
  return expected_bytes;
}

#if defined(FFI_UVC_HAS_JPEG)
// libjpeg's default error handler calls exit(); route fatal errors back
// through setjmp instead so a bad frame cannot take down the process.
typedef struct {
  struct jpeg_error_mgr base;
  jmp_buf jump;
} ffi_uvc_jpeg_error_mgr_t;

static void ffi_uvc_jpeg_error_exit(j_common_ptr cinfo) {
  ffi_uvc_jpeg_error_mgr_t *err = (ffi_uvc_jpeg_error_mgr_t *)cinfo->err;
  longjmp(err->jump, 1);
}
#endif

FFI_PLUGIN_EXPORT int uvc_take_picture_jpeg(
    uvc_session_t *s,
    uint8_t *buffer,
    int buffer_length,
    int quality,
    int rotation,
    int flip_h,
    int flip_v,
    int *out_width,
    int *out_height,
    int64_t *out_sequence) {
  if (s == NULL) {
    return UVC_ERROR_INVALID_PARAM;
  }
#if !defined(FFI_UVC_HAS_JPEG)
  (void)buffer; (void)buffer_length; (void)quality;
  (void)rotation; (void)flip_h; (void)flip_v;
  (void)out_width; (void)out_height; (void)out_sequence;
  set_last_error(s, "JPEG encoder is not available in this build");
  return 0;
#else
  if (buffer == NULL || buffer_length <= 0) {
    return 0;
  }

  int r = rotation % 360;
  if (r < 0) r += 360;
  if (r != 0 && r != 90 && r != 180 && r != 270) r = 0;
  const int fh = flip_h ? 1 : 0;
  const int fv = flip_v ? 1 : 0;
  int q = quality;
  if (q < 1) q = 1;
  if (q > 100) q = 100;

  pthread_mutex_lock(&s->mutex);
  if (s->latest_rgba == NULL || s->latest_rgba_bytes == 0) {
    pthread_mutex_unlock(&s->mutex);
    set_last_error(s, "No preview frame available to capture");
    return 0;
  }

  const int src_w = s->frame_width;
  const int src_h = s->frame_height;
  const int dst_w = (r == 90 || r == 270) ? src_h : src_w;
  const int dst_h = (r == 90 || r == 270) ? src_w : src_h;
  const size_t rgba_bytes = (size_t)dst_w * (size_t)dst_h * 4u;

  uint8_t *rgba = malloc(rgba_bytes);
  if (rgba == NULL) {
    pthread_mutex_unlock(&s->mutex);
    set_last_error(s, "Failed to allocate %zu bytes for capture frame", rgba_bytes);
    return 0;
  }

  blit_rgba_transform(
      (const uint32_t *)s->latest_rgba, src_w, src_h,
      (uint32_t *)rgba, dst_w, r, fh, fv);
  const int64_t sequence = s->latest_sequence;
  pthread_mutex_unlock(&s->mutex);

  // Encode outside the state mutex so the stream callback never blocks
  // behind JPEG compression. `out`/`out_size` are volatile because
  // jpeg_mem_dest may rewrite them between setjmp and a longjmp.
  struct jpeg_compress_struct cinfo;
  ffi_uvc_jpeg_error_mgr_t err;
  unsigned char *volatile out = buffer;
  volatile unsigned long out_size = (unsigned long)buffer_length;

  cinfo.err = jpeg_std_error(&err.base);
  err.base.error_exit = ffi_uvc_jpeg_error_exit;
  if (setjmp(err.jump)) {
    char message[JMSG_LENGTH_MAX];
    (*cinfo.err->format_message)((j_common_ptr)&cinfo, message);
    jpeg_destroy_compress(&cinfo);
    if (out != buffer) {
      free(out);
    }
    free(rgba);
    set_last_error(s, "JPEG encode failed: %s", message);
    return 0;
  }

  jpeg_create_compress(&cinfo);
  jpeg_mem_dest(&cinfo, (unsigned char **)&out, (unsigned long *)&out_size);
  cinfo.image_width = (JDIMENSION)dst_w;
  cinfo.image_height = (JDIMENSION)dst_h;
  cinfo.input_components = 4;
  cinfo.in_color_space = JCS_EXT_RGBA;
  jpeg_set_defaults(&cinfo);
  jpeg_set_quality(&cinfo, q, TRUE);
  jpeg_start_compress(&cinfo, TRUE);
  while (cinfo.next_scanline < cinfo.image_height) {
    JSAMPROW row = rgba + (size_t)cinfo.next_scanline * (size_t)dst_w * 4u;
    jpeg_write_scanlines(&cinfo, &row, 1);
  }
  jpeg_finish_compress(&cinfo);
  jpeg_destroy_compress(&cinfo);
  free(rgba);

  // jpeg_mem_dest grows into a fresh malloc'd buffer when the caller's buffer
  // is too small; the result only counts if it still fits the caller's buffer.
  if (out != buffer) {
    const int fits = out_size <= (unsigned long)buffer_length;
    if (fits) {
      memcpy(buffer, out, out_size);
    }
    free(out);
    if (!fits) {
      set_last_error(s,
          "JPEG output (%lu bytes) exceeds capture buffer (%d bytes)",
          (unsigned long)out_size, buffer_length);
      return 0;
    }
  }

  if (out_width != NULL) *out_width = dst_w;
  if (out_height != NULL) *out_height = dst_h;
  if (out_sequence != NULL) *out_sequence = sequence;
  return (int)out_size;
#endif
}

FFI_PLUGIN_EXPORT void uvc_set_frame_listener(
    uvc_session_t *s,
    uvc_frame_listener_t listener,
    void *user_data) {
  if (s == NULL) {
    return;
  }
  pthread_mutex_lock(&s->listener_mutex);
  s->frame_listener = listener;
  s->frame_listener_user_data = listener != NULL ? user_data : NULL;
  pthread_mutex_unlock(&s->listener_mutex);
}

FFI_PLUGIN_EXPORT void uvc_set_error_listener(
    uvc_session_t *s,
    uvc_error_listener_t listener,
    void *user_data) {
  if (s == NULL) {
    return;
  }
  pthread_mutex_lock(&s->listener_mutex);
  s->error_listener = listener;
  s->error_listener_user_data = listener != NULL ? user_data : NULL;
  pthread_mutex_unlock(&s->listener_mutex);
}

// Test-only: injects an RGBA buffer directly into the shared frame state.
// Not declared in the public header — accessed only via test-specific bindings.
FFI_PLUGIN_EXPORT void uvc_inject_test_frame_rgba(
    uvc_session_t *s, const uint8_t *buffer, int width, int height) {
  if (s == NULL || buffer == NULL || width <= 0 || height <= 0) return;

  const size_t rgba_bytes = (size_t)width * (size_t)height * 4;

  pthread_mutex_lock(&s->mutex);
  uint8_t *new_buffer = realloc(s->latest_rgba, rgba_bytes);
  if (new_buffer != NULL) {
    s->latest_rgba = new_buffer;
    s->latest_rgba_bytes = rgba_bytes;
    memcpy(s->latest_rgba, buffer, rgba_bytes);
    s->frame_width = width;
    s->frame_height = height;
    s->latest_sequence += 1;
  }
  pthread_mutex_unlock(&s->mutex);
}

// Test-only: fires error_listener with a caller-supplied message.
// Not declared in the public header — accessed only via test-specific bindings.
FFI_PLUGIN_EXPORT void uvc_trigger_test_error(uvc_session_t *s, const char *message) {
  if (s == NULL) return;
  const char *msg = message != NULL ? message : "test error";
  pthread_mutex_lock(&s->mutex);
  set_last_error(s, "%s", msg);
  const char *staged = stage_error_ring_locked(s);
  uvc_error_listener_t listener = s->error_listener;
  void *user_data = s->error_listener_user_data;
  pthread_mutex_unlock(&s->mutex);
  if (listener) listener(user_data, staged);
}

FFI_PLUGIN_EXPORT const char *uvc_last_error(uvc_session_t *s) {
  if (s == NULL) {
    return k_empty_last_error;
  }
  pthread_mutex_lock(&s->error_mutex);
  memcpy(s->last_error_snapshot, s->last_error, sizeof(s->last_error_snapshot));
  pthread_mutex_unlock(&s->error_mutex);
  s->last_error_snapshot[sizeof(s->last_error_snapshot) - 1] = '\0';
  return s->last_error_snapshot;
}

FFI_PLUGIN_EXPORT void uvc_set_preview_transform(
    uvc_session_t *s,
    int rotation,
    int flip_h,
    int flip_v) {
  if (s == NULL) {
    return;
  }
  // Normalise rotation to one of 0/90/180/270.
  int r = rotation % 360;
  if (r < 0) r += 360;
  if (r != 0 && r != 90 && r != 180 && r != 270) r = 0;

  pthread_mutex_lock(&s->mutex);
  s->preview_rotation = r;
  s->preview_flip_h = flip_h ? 1 : 0;
  s->preview_flip_v = flip_v ? 1 : 0;
  pthread_mutex_unlock(&s->mutex);
}

FFI_PLUGIN_EXPORT void uvc_get_preview_transform(
    uvc_session_t *s,
    int *rotation,
    int *flip_h,
    int *flip_v) {
  if (s == NULL) {
    return;
  }
  pthread_mutex_lock(&s->mutex);
  if (rotation != NULL) *rotation = s->preview_rotation;
  if (flip_h != NULL) *flip_h = s->preview_flip_h;
  if (flip_v != NULL) *flip_v = s->preview_flip_v;
  pthread_mutex_unlock(&s->mutex);
}

// ---------------------------------------------------------------------------
// Video recording (MP4 / H.264 via AMediaCodec + AMediaMuxer)
// ---------------------------------------------------------------------------

#if defined(__ANDROID__)

#include <dlfcn.h>

// MediaCodecInfo.CodecCapabilities color formats. Hardware encoders almost
// universally accept semi-planar (NV12); planar (I420) is the fallback for
// the remainder.
#define REC_COLOR_FORMAT_NV12 21
#define REC_COLOR_FORMAT_I420 19

// BT.601 limited-range RGBA -> YUV420 into the encoder input buffer, honoring
// the encoder's stride and slice height. Dimensions must be even.
static void rec_convert_rgba_to_yuv(uvc_session_t *s,
    const uint8_t *rgba, int w, int h, uint8_t *dst) {
  const int stride = s->rec.enc_stride;
  const int slice = s->rec.enc_slice_height;
  uint8_t *y_plane = dst;
  uint8_t *chroma = dst + (size_t)stride * (size_t)slice;

  for (int row = 0; row < h; ++row) {
    const uint8_t *src = rgba + (size_t)row * (size_t)w * 4u;
    uint8_t *y_out = y_plane + (size_t)row * (size_t)stride;
    for (int col = 0; col < w; ++col) {
      const int r = src[col * 4 + 0];
      const int g = src[col * 4 + 1];
      const int b = src[col * 4 + 2];
      y_out[col] = (uint8_t)(((66 * r + 129 * g + 25 * b + 128) >> 8) + 16);
    }
  }

  for (int row = 0; row < h; row += 2) {
    const uint8_t *src0 = rgba + (size_t)row * (size_t)w * 4u;
    const uint8_t *src1 = src0 + (size_t)w * 4u;
    for (int col = 0; col < w; col += 2) {
      const int r = (src0[col * 4 + 0] + src0[col * 4 + 4] +
                     src1[col * 4 + 0] + src1[col * 4 + 4] + 2) >> 2;
      const int g = (src0[col * 4 + 1] + src0[col * 4 + 5] +
                     src1[col * 4 + 1] + src1[col * 4 + 5] + 2) >> 2;
      const int b = (src0[col * 4 + 2] + src0[col * 4 + 6] +
                     src1[col * 4 + 2] + src1[col * 4 + 6] + 2) >> 2;
      const uint8_t u = (uint8_t)(((-38 * r - 74 * g + 112 * b + 128) >> 8) + 128);
      const uint8_t v = (uint8_t)(((112 * r - 94 * g - 18 * b + 128) >> 8) + 128);
      if (s->rec.color_format == REC_COLOR_FORMAT_NV12) {
        uint8_t *uv = chroma + (size_t)(row / 2) * (size_t)stride;
        uv[col + 0] = u;
        uv[col + 1] = v;
      } else {
        const size_t c_stride = (size_t)stride / 2;
        uint8_t *u_plane = chroma;
        uint8_t *v_plane = chroma + c_stride * (size_t)(slice / 2);
        u_plane[(size_t)(row / 2) * c_stride + (size_t)(col / 2)] = u;
        v_plane[(size_t)(row / 2) * c_stride + (size_t)(col / 2)] = v;
      }
    }
  }
}

static size_t rec_yuv_frame_bytes(uvc_session_t *s, int h) {
  const size_t stride = (size_t)s->rec.enc_stride;
  const size_t chroma_offset = stride * (size_t)s->rec.enc_slice_height;
  if (s->rec.color_format == REC_COLOR_FORMAT_NV12) {
    return chroma_offset + stride * (size_t)(h / 2);
  }
  const size_t c_stride = stride / 2;
  return chroma_offset + c_stride * (size_t)(s->rec.enc_slice_height / 2) +
         c_stride * (size_t)(h / 2);
}

// Moves encoded output into the muxer. Returns 0 on fatal muxer failure,
// 1 when drained, 2 when the end-of-stream sample was consumed.
static int rec_drain_encoder(uvc_session_t *s, int64_t timeout_us) {
  while (1) {
    AMediaCodecBufferInfo info;
    const ssize_t idx =
        AMediaCodec_dequeueOutputBuffer(s->rec.codec, &info, timeout_us);
    if (idx == AMEDIACODEC_INFO_OUTPUT_FORMAT_CHANGED) {
      AMediaFormat *format = AMediaCodec_getOutputFormat(s->rec.codec);
      if (format == NULL) {
        return 0;
      }
      s->rec.video_track = AMediaMuxer_addTrack(s->rec.muxer, format);
      AMediaFormat_delete(format);
      if (s->rec.video_track < 0 ||
          AMediaMuxer_start(s->rec.muxer) != AMEDIA_OK) {
        return 0;
      }
      s->rec.muxer_started = 1;
      continue;
    }
    if (idx == AMEDIACODEC_INFO_OUTPUT_BUFFERS_CHANGED) {
      continue;
    }
    if (idx < 0) {
      return 1;  // AMEDIACODEC_INFO_TRY_AGAIN_LATER or unknown: drained
    }

    size_t out_capacity = 0;
    uint8_t *out = AMediaCodec_getOutputBuffer(s->rec.codec, idx, &out_capacity);
    if (out != NULL && info.size > 0 && s->rec.muxer_started &&
        (info.flags & AMEDIACODEC_BUFFER_FLAG_CODEC_CONFIG) == 0) {
      AMediaMuxer_writeSampleData(s->rec.muxer, (size_t)s->rec.video_track, out,
                                  &info);
      s->rec.frames_submitted += 1;
    }
    const int eos = (info.flags & AMEDIACODEC_BUFFER_FLAG_END_OF_STREAM) != 0;
    AMediaCodec_releaseOutputBuffer(s->rec.codec, idx, false);
    if (eos) {
      return 2;
    }
  }
}

static void rec_encode_frame(uvc_session_t *s, uint64_t ts_ns) {
  const uint8_t *frame = s->rec.rgba_copy;
  if (s->rec.rgba_transformed != NULL) {
    blit_rgba_transform(
        (const uint32_t *)s->rec.rgba_copy, s->rec.src_width, s->rec.src_height,
        (uint32_t *)s->rec.rgba_transformed, s->rec.out_width,
        s->rec.rotation, s->rec.flip_h, s->rec.flip_v);
    frame = s->rec.rgba_transformed;
  }

  if (!s->rec.has_base) {
    s->rec.base_ns = ts_ns;
    s->rec.has_base = 1;
  }
  int64_t pts_us = (int64_t)((ts_ns - s->rec.base_ns) / 1000u);
  if (pts_us <= s->rec.last_pts_us) {
    pts_us = s->rec.last_pts_us + 1000;
  }

  const ssize_t idx = AMediaCodec_dequeueInputBuffer(s->rec.codec, 10000);
  if (idx < 0) {
    s->rec.frames_dropped += 1;
    return;
  }
  size_t capacity = 0;
  uint8_t *input = AMediaCodec_getInputBuffer(s->rec.codec, idx, &capacity);
  const size_t needed = rec_yuv_frame_bytes(s, s->rec.out_height);
  if (input == NULL || capacity < needed) {
    AMediaCodec_queueInputBuffer(s->rec.codec, idx, 0, 0, (uint64_t)pts_us, 0);
    s->rec.frames_dropped += 1;
    return;
  }
  rec_convert_rgba_to_yuv(s, frame, s->rec.out_width, s->rec.out_height, input);
  if (AMediaCodec_queueInputBuffer(s->rec.codec, idx, 0, needed,
                                   (uint64_t)pts_us, 0) != AMEDIA_OK) {
    s->rec.frames_dropped += 1;
    return;
  }
  s->rec.last_pts_us = pts_us;
  rec_drain_encoder(s, 0);
}

static void *recording_thread_main(void *arg) {
  uvc_session_t *s = (uvc_session_t *)arg;
  while (1) {
    pthread_mutex_lock(&s->mutex);
    while (!s->rec.stop_requested &&
           (s->latest_rgba == NULL ||
            s->latest_sequence <= s->rec.last_sequence)) {
      pthread_cond_wait(&s->recording_cond, &s->mutex);
    }
    if (s->rec.stop_requested) {
      pthread_mutex_unlock(&s->mutex);
      break;
    }
    const int w = s->frame_width;
    const int h = s->frame_height;
    const uint64_t ts_ns = s->stats.last_delivered_monotonic_ns;
    s->rec.last_sequence = s->latest_sequence;
    const int matches = w == s->rec.src_width && h == s->rec.src_height;
    if (matches) {
      memcpy(s->rec.rgba_copy, s->latest_rgba,
             (size_t)w * (size_t)h * 4u);
    }
    pthread_mutex_unlock(&s->mutex);

    if (!matches) {
      s->rec.frames_dropped += 1;
      continue;
    }
    rec_encode_frame(s, ts_ns != 0 ? ts_ns : monotonic_time_ns());
  }
  return NULL;
}

// Frees every recording resource. Safe to call with partially initialized
// state. Leaves s->rec zeroed.
static void rec_release_resources(uvc_session_t *s) {
  if (s->rec.codec != NULL) {
    AMediaCodec_stop(s->rec.codec);
    AMediaCodec_delete(s->rec.codec);
  }
  if (s->rec.muxer != NULL) {
    AMediaMuxer_delete(s->rec.muxer);
  }
  if (s->rec.fd >= 0) {
    close(s->rec.fd);
  }
  free(s->rec.rgba_copy);
  free(s->rec.rgba_transformed);
  memset(&s->rec, 0, sizeof(s->rec));
  s->rec.fd = -1;
  s->rec.video_track = -1;
}

// Creates and configures the H.264 encoder, trying semi-planar first. The
// codec is recreated per attempt because a failed configure leaves it in an
// unusable state.
static int rec_create_encoder(uvc_session_t *s, int bitrate_bps, int fps) {
  static const int color_formats[] = {REC_COLOR_FORMAT_NV12,
                                      REC_COLOR_FORMAT_I420};
  for (size_t i = 0; i < sizeof(color_formats) / sizeof(color_formats[0]);
       ++i) {
    AMediaCodec *codec = AMediaCodec_createEncoderByType("video/avc");
    if (codec == NULL) {
      set_last_error(s, "No H.264 (video/avc) encoder available");
      return 0;
    }
    AMediaFormat *format = AMediaFormat_new();
    AMediaFormat_setString(format, AMEDIAFORMAT_KEY_MIME, "video/avc");
    AMediaFormat_setInt32(format, AMEDIAFORMAT_KEY_WIDTH, s->rec.out_width);
    AMediaFormat_setInt32(format, AMEDIAFORMAT_KEY_HEIGHT, s->rec.out_height);
    AMediaFormat_setInt32(format, AMEDIAFORMAT_KEY_COLOR_FORMAT,
                          color_formats[i]);
    AMediaFormat_setInt32(format, AMEDIAFORMAT_KEY_BIT_RATE, bitrate_bps);
    AMediaFormat_setInt32(format, AMEDIAFORMAT_KEY_FRAME_RATE, fps);
    AMediaFormat_setInt32(format, AMEDIAFORMAT_KEY_I_FRAME_INTERVAL, 1);
    const media_status_t configured = AMediaCodec_configure(
        codec, format, NULL, NULL, AMEDIACODEC_CONFIGURE_FLAG_ENCODE);
    AMediaFormat_delete(format);
    if (configured != AMEDIA_OK) {
      AMediaCodec_delete(codec);
      continue;
    }
    if (AMediaCodec_start(codec) != AMEDIA_OK) {
      AMediaCodec_delete(codec);
      continue;
    }
    s->rec.codec = codec;
    s->rec.color_format = color_formats[i];
    return 1;
  }
  set_last_error(s,
      "H.264 encoder rejected both YUV420 semi-planar and planar input");
  return 0;
}

// The encoder may pad rows and planes; honor its reported stride and slice
// height. AMediaCodec_getInputFormat only exists from API 28, so resolve it
// dynamically and fall back to unpadded dimensions below.
static void rec_query_encoder_layout(uvc_session_t *s) {
  s->rec.enc_stride = s->rec.out_width;
  s->rec.enc_slice_height = s->rec.out_height;

  typedef AMediaFormat *(*get_input_format_fn)(AMediaCodec *);
  const get_input_format_fn get_input_format =
      (get_input_format_fn)dlsym(RTLD_DEFAULT, "AMediaCodec_getInputFormat");
  if (get_input_format == NULL) {
    return;
  }
  AMediaFormat *format = get_input_format(s->rec.codec);
  if (format == NULL) {
    return;
  }
  int32_t stride = 0;
  int32_t slice_height = 0;
  if (AMediaFormat_getInt32(format, "stride", &stride) &&
      stride >= s->rec.out_width) {
    s->rec.enc_stride = stride;
  }
  if (AMediaFormat_getInt32(format, "slice-height", &slice_height) &&
      slice_height >= s->rec.out_height) {
    s->rec.enc_slice_height = slice_height;
  }
  AMediaFormat_delete(format);
}

FFI_PLUGIN_EXPORT int uvc_start_recording(
    uvc_session_t *s,
    const char *path,
    int bitrate_bps,
    int fps_hint,
    int rotation,
    int flip_h,
    int flip_v) {
  if (s == NULL) {
    return UVC_ERROR_INVALID_PARAM;
  }
  if (path == NULL || path[0] == '\0') {
    set_last_error(s, "Recording path must not be empty");
    return UVC_ERROR_INVALID_PARAM;
  }

  int r = rotation % 360;
  if (r < 0) r += 360;
  if (r != 0 && r != 90 && r != 180 && r != 270) r = 0;
  const int fps = fps_hint > 0 ? fps_hint : 30;

  pthread_mutex_lock(&s->mutex);
  if (s->recording_active) {
    set_last_error(s, "A recording is already in progress");
    pthread_mutex_unlock(&s->mutex);
    return UVC_ERROR_BUSY;
  }
  if (!s->previewing || s->latest_rgba == NULL ||
      s->frame_width <= 0 || s->frame_height <= 0) {
    set_last_error(s, "Recording requires an active preview with delivered frames");
    pthread_mutex_unlock(&s->mutex);
    return UVC_ERROR_INVALID_MODE;
  }

  memset(&s->rec, 0, sizeof(s->rec));
  s->rec.fd = -1;
  s->rec.video_track = -1;
  s->rec.src_width = s->frame_width;
  s->rec.src_height = s->frame_height;
  s->rec.rotation = r;
  s->rec.flip_h = flip_h ? 1 : 0;
  s->rec.flip_v = flip_v ? 1 : 0;
  s->rec.out_width = (r == 90 || r == 270) ? s->rec.src_height : s->rec.src_width;
  s->rec.out_height = (r == 90 || r == 270) ? s->rec.src_width : s->rec.src_height;
  s->rec.last_pts_us = -1;
  // Start with the current frame: the thread records sequences newer than this.
  s->rec.last_sequence = s->latest_sequence - 1;

  if ((s->rec.out_width % 2) != 0 || (s->rec.out_height % 2) != 0) {
    set_last_error(s,
        "Recording requires even frame dimensions, got %dx%d",
        s->rec.out_width, s->rec.out_height);
    pthread_mutex_unlock(&s->mutex);
    return UVC_ERROR_INVALID_PARAM;
  }

  int bitrate = bitrate_bps;
  if (bitrate <= 0) {
    const int64_t heuristic =
        (int64_t)s->rec.out_width * s->rec.out_height * fps / 10;
    bitrate = (int)(heuristic < 300000 ? 300000
                    : heuristic > 50000000 ? 50000000
                                           : heuristic);
  }

  s->rec.fd = open(path, O_CREAT | O_WRONLY | O_TRUNC, 0644);
  if (s->rec.fd < 0) {
    set_last_error(s, "Failed to open recording file: %s", path);
    rec_release_resources(s);
    pthread_mutex_unlock(&s->mutex);
    return UVC_ERROR_IO;
  }

  if (!rec_create_encoder(s, bitrate, fps)) {
    rec_release_resources(s);
    pthread_mutex_unlock(&s->mutex);
    return UVC_ERROR_NOT_SUPPORTED;
  }
  rec_query_encoder_layout(s);

  s->rec.muxer = AMediaMuxer_new(s->rec.fd, AMEDIAMUXER_OUTPUT_FORMAT_MPEG_4);
  if (s->rec.muxer == NULL) {
    set_last_error(s, "Failed to create MP4 muxer");
    rec_release_resources(s);
    pthread_mutex_unlock(&s->mutex);
    return UVC_ERROR_OTHER;
  }

  const size_t src_bytes =
      (size_t)s->rec.src_width * (size_t)s->rec.src_height * 4u;
  s->rec.rgba_copy = malloc(src_bytes);
  const int needs_transform = r != 0 || s->rec.flip_h || s->rec.flip_v;
  s->rec.rgba_transformed = needs_transform ? malloc(src_bytes) : NULL;
  if (s->rec.rgba_copy == NULL || (needs_transform && s->rec.rgba_transformed == NULL)) {
    set_last_error(s, "Failed to allocate recording frame buffers");
    rec_release_resources(s);
    pthread_mutex_unlock(&s->mutex);
    return UVC_ERROR_NO_MEM;
  }

  if (pthread_create(&s->rec.thread, NULL, recording_thread_main, s) != 0) {
    set_last_error(s, "Failed to start recording thread");
    rec_release_resources(s);
    pthread_mutex_unlock(&s->mutex);
    return UVC_ERROR_OTHER;
  }
  s->rec.thread_started = 1;
  s->recording_active = 1;
  clear_last_error(s);
  UVC_LOGI(
      "UVC_NATIVE",
      "uvc_start_recording success path=%s size=%dx%d fps=%d bitrate=%d colorFormat=%d",
      path, s->rec.out_width, s->rec.out_height, fps, bitrate,
      s->rec.color_format);
  pthread_mutex_unlock(&s->mutex);
  return UVC_SUCCESS;
}

FFI_PLUGIN_EXPORT int uvc_stop_recording(uvc_session_t *s) {
  if (s == NULL) {
    return UVC_ERROR_INVALID_PARAM;
  }
  pthread_mutex_lock(&s->mutex);
  if (!s->recording_active) {
    pthread_mutex_unlock(&s->mutex);
    return UVC_SUCCESS;
  }
  s->recording_active = 0;
  s->rec.stop_requested = 1;
  pthread_cond_broadcast(&s->recording_cond);
  pthread_mutex_unlock(&s->mutex);

  pthread_join(s->rec.thread, NULL);
  s->rec.thread_started = 0;

  // Flush the encoder with an end-of-stream buffer and mux the tail.
  const ssize_t eos_idx = AMediaCodec_dequeueInputBuffer(s->rec.codec, 100000);
  if (eos_idx >= 0) {
    AMediaCodec_queueInputBuffer(
        s->rec.codec, eos_idx, 0, 0,
        (uint64_t)(s->rec.last_pts_us > 0 ? s->rec.last_pts_us + 1000 : 0),
        AMEDIACODEC_BUFFER_FLAG_END_OF_STREAM);
    for (int attempt = 0; attempt < 200; ++attempt) {
      const int drained = rec_drain_encoder(s, 10000);
      if (drained == 0 || drained == 2) {
        break;
      }
    }
  } else {
    rec_drain_encoder(s, 10000);
  }

  int result = UVC_SUCCESS;
  if (s->rec.muxer_started) {
    if (AMediaMuxer_stop(s->rec.muxer) != AMEDIA_OK) {
      set_last_error(s, "Failed to finalize MP4 file");
      result = UVC_ERROR_IO;
    }
  } else {
    set_last_error(s, "Recording produced no encoded frames");
    result = UVC_ERROR_IO;
  }
  UVC_LOGI(
      "UVC_NATIVE",
      "uvc_stop_recording result=%d samplesWritten=%" PRIu64 " dropped=%" PRIu64,
      result, s->rec.frames_submitted, s->rec.frames_dropped);
  rec_release_resources(s);
  return result;
}

FFI_PLUGIN_EXPORT int uvc_is_recording(uvc_session_t *s) {
  if (s == NULL) {
    return UVC_ERROR_INVALID_PARAM;
  }
  pthread_mutex_lock(&s->mutex);
  const int recording = s->recording_active;
  pthread_mutex_unlock(&s->mutex);
  return recording;
}

#else  // !defined(__ANDROID__)

FFI_PLUGIN_EXPORT int uvc_start_recording(
    uvc_session_t *s,
    const char *path,
    int bitrate_bps,
    int fps_hint,
    int rotation,
    int flip_h,
    int flip_v) {
  (void)path; (void)bitrate_bps; (void)fps_hint;
  (void)rotation; (void)flip_h; (void)flip_v;
  if (s == NULL) {
    return UVC_ERROR_INVALID_PARAM;
  }
  set_last_error(s, "Video recording is not available in this build");
  return UVC_ERROR_NOT_SUPPORTED;
}

FFI_PLUGIN_EXPORT int uvc_stop_recording(uvc_session_t *s) {
  return s != NULL ? UVC_SUCCESS : UVC_ERROR_INVALID_PARAM;
}

FFI_PLUGIN_EXPORT int uvc_is_recording(uvc_session_t *s) {
  return s != NULL ? 0 : UVC_ERROR_INVALID_PARAM;
}

#endif  // defined(__ANDROID__)

// ---------------------------------------------------------------------------
// CT / PU camera control helpers
// ---------------------------------------------------------------------------

typedef enum {
  CTRL_VALUE_TYPE_INT16,
  CTRL_VALUE_TYPE_UINT16,
  CTRL_VALUE_TYPE_UINT32,
  CTRL_VALUE_TYPE_UINT8,
} ctrl_value_type_t;

typedef struct {
  int id;
  const char *name;
  const char *label;
  ctrl_value_type_t value_type;
  // "slider", "bool", "enum"
  const char *ui_type;
  // 1 = Camera Terminal (CT), 0 = Processing Unit (PU)
  int is_ct;
  // Bit position in bmControls = (UVC selector value - 1)
  int bm_bit;
} ctrl_info_t;

static const ctrl_info_t k_ctrl_table[] = {
    // PU controls — bm_bit = UVC_PU_*_CONTROL selector - 1
    {UVC_CTRL_ID_BRIGHTNESS,                "brightness",                  "Brightness",                 CTRL_VALUE_TYPE_INT16,  "slider", 0, 1},  // PU selector 0x02
    {UVC_CTRL_ID_CONTRAST,                  "contrast",                    "Contrast",                   CTRL_VALUE_TYPE_UINT16, "slider", 0, 2},  // PU selector 0x03
    {UVC_CTRL_ID_HUE,                       "hue",                         "Hue",                        CTRL_VALUE_TYPE_INT16,  "slider", 0, 5},  // PU selector 0x06
    {UVC_CTRL_ID_SATURATION,                "saturation",                  "Saturation",                 CTRL_VALUE_TYPE_UINT16, "slider", 0, 6},  // PU selector 0x07
    {UVC_CTRL_ID_SHARPNESS,                 "sharpness",                   "Sharpness",                  CTRL_VALUE_TYPE_UINT16, "slider", 0, 7},  // PU selector 0x08
    {UVC_CTRL_ID_GAMMA,                     "gamma",                       "Gamma",                      CTRL_VALUE_TYPE_UINT16, "slider", 0, 8},  // PU selector 0x09
    {UVC_CTRL_ID_GAIN,                      "gain",                        "Gain",                       CTRL_VALUE_TYPE_UINT16, "slider", 0, 3},  // PU selector 0x04
    {UVC_CTRL_ID_BACKLIGHT_COMPENSATION,    "backlight_compensation",      "Backlight Compensation",     CTRL_VALUE_TYPE_UINT16, "slider", 0, 0},  // PU selector 0x01
    {UVC_CTRL_ID_WHITE_BALANCE_TEMPERATURE, "white_balance_temperature",   "White Balance Temperature",  CTRL_VALUE_TYPE_UINT16, "slider", 0, 9},  // PU selector 0x0a
    {UVC_CTRL_ID_WHITE_BALANCE_TEMP_AUTO,   "white_balance_temp_auto",     "Auto White Balance",         CTRL_VALUE_TYPE_UINT8,  "bool",   0, 10}, // PU selector 0x0b
    {UVC_CTRL_ID_POWER_LINE_FREQUENCY,      "power_line_frequency",        "Power Line Frequency",       CTRL_VALUE_TYPE_UINT8,  "enum",   0, 4},  // PU selector 0x05
    {UVC_CTRL_ID_CONTRAST_AUTO,             "contrast_auto",               "Auto Contrast",              CTRL_VALUE_TYPE_UINT8,  "bool",   0, 18}, // PU selector 0x13
    {UVC_CTRL_ID_HUE_AUTO,                  "hue_auto",                    "Auto Hue",                   CTRL_VALUE_TYPE_UINT8,  "bool",   0, 15}, // PU selector 0x10
    {UVC_CTRL_ID_WHITE_BALANCE_COMPONENT_AUTO, "white_balance_component_auto", "Auto White Balance Component", CTRL_VALUE_TYPE_UINT8, "bool", 0, 12}, // PU selector 0x0d
    {UVC_CTRL_ID_DIGITAL_MULTIPLIER,        "digital_multiplier",          "Digital Multiplier",         CTRL_VALUE_TYPE_UINT16, "slider", 0, 13}, // PU selector 0x0e
    {UVC_CTRL_ID_DIGITAL_MULTIPLIER_LIMIT,  "digital_multiplier_limit",    "Digital Multiplier Limit",   CTRL_VALUE_TYPE_UINT16, "slider", 0, 14}, // PU selector 0x0f
    {UVC_CTRL_ID_ANALOG_VIDEO_STANDARD,     "analog_video_standard",       "Analog Video Standard",      CTRL_VALUE_TYPE_UINT8,  "enum",   0, 16}, // PU selector 0x11
    {UVC_CTRL_ID_ANALOG_LOCK_STATUS,        "analog_lock_status",          "Analog Lock Status",         CTRL_VALUE_TYPE_UINT8,  "enum",   0, 17}, // PU selector 0x12
    // CT controls — bm_bit = UVC_CT_*_CONTROL selector - 1
    {UVC_CTRL_ID_SCANNING_MODE,             "scanning_mode",               "Scanning Mode",              CTRL_VALUE_TYPE_UINT8,  "bool",   1, 0},  // CT selector 0x01
    {UVC_CTRL_ID_AE_MODE,                   "ae_mode",                     "Exposure Mode",             CTRL_VALUE_TYPE_UINT8,  "enum",   1, 1},  // CT selector 0x02
    {UVC_CTRL_ID_AE_PRIORITY,               "ae_priority",                 "AE Priority",               CTRL_VALUE_TYPE_UINT8,  "bool",   1, 2},  // CT selector 0x03
    {UVC_CTRL_ID_EXPOSURE_ABS,              "exposure_abs",                "Exposure Time",             CTRL_VALUE_TYPE_UINT32, "slider", 1, 3},  // CT selector 0x04
    {UVC_CTRL_ID_EXPOSURE_REL,              "exposure_rel",                "Exposure Step",              CTRL_VALUE_TYPE_UINT8,  "slider", 1, 4},  // CT selector 0x05
    {UVC_CTRL_ID_FOCUS_ABS,                 "focus_abs",                   "Focus",                     CTRL_VALUE_TYPE_UINT16, "slider", 1, 5},  // CT selector 0x06
    {UVC_CTRL_ID_FOCUS_AUTO,                "focus_auto",                  "Auto Focus",                CTRL_VALUE_TYPE_UINT8,  "bool",   1, 7},  // CT selector 0x08
    {UVC_CTRL_ID_IRIS_ABS,                  "iris_abs",                    "Iris",                      CTRL_VALUE_TYPE_UINT16, "slider", 1, 8},  // CT selector 0x09
    {UVC_CTRL_ID_IRIS_REL,                  "iris_rel",                    "Iris Step",                 CTRL_VALUE_TYPE_UINT8,  "slider", 1, 9},  // CT selector 0x0a
    {UVC_CTRL_ID_ZOOM_ABS,                  "zoom_abs",                    "Zoom",                      CTRL_VALUE_TYPE_UINT16, "slider", 1, 10}, // CT selector 0x0b
    {UVC_CTRL_ID_ROLL_ABS,                  "roll_abs",                    "Roll",                      CTRL_VALUE_TYPE_INT16,  "slider", 1, 14}, // CT selector 0x0f
    {UVC_CTRL_ID_PRIVACY,                   "privacy",                     "Privacy",                   CTRL_VALUE_TYPE_UINT8,  "bool",   1, 16}, // CT selector 0x11
    {UVC_CTRL_ID_FOCUS_SIMPLE,              "focus_simple",                "Simple Focus",              CTRL_VALUE_TYPE_UINT8,  "enum",   1, 17}, // CT selector 0x12
};

static const int k_ctrl_table_size = (int)(sizeof(k_ctrl_table) / sizeof(k_ctrl_table[0]));

static const char *ctrl_name_for_id(int ctrl_id) {
  for (int i = 0; i < k_ctrl_table_size; ++i) {
    if (k_ctrl_table[i].id == ctrl_id) {
      return k_ctrl_table[i].name;
    }
  }
  return "unknown";
}

static const char *uvc_req_code_name(enum uvc_req_code req_code) {
  switch (req_code) {
    case UVC_SET_CUR:
      return "SET_CUR";
    case UVC_GET_CUR:
      return "GET_CUR";
    case UVC_GET_MIN:
      return "GET_MIN";
    case UVC_GET_MAX:
      return "GET_MAX";
    case UVC_GET_RES:
      return "GET_RES";
    case UVC_GET_LEN:
      return "GET_LEN";
    case UVC_GET_INFO:
      return "GET_INFO";
    case UVC_GET_DEF:
      return "GET_DEF";
    default:
      return "UNKNOWN";
  }
}

// Returns 1 on success, 0 if not supported
static int ctrl_get_raw(uvc_device_handle_t *devh, int ctrl_id,
                        enum uvc_req_code req_code, int32_t *out_value) {
  int8_t   v8s  = 0;
  int16_t  v16s = 0;
  uint16_t v16u = 0;
  uint32_t v32u = 0;
  uint8_t  v8u  = 0;
  uvc_error_t res = UVC_ERROR_NOT_SUPPORTED;
  const char *ctrl_name = ctrl_name_for_id(ctrl_id);

  UVC_LOGD(
      "UVC_NATIVE",
      "ctrl request begin id=%d name=%s req=%s",
      ctrl_id,
      ctrl_name,
      uvc_req_code_name(req_code));

  switch (ctrl_id) {
    case UVC_CTRL_ID_SCANNING_MODE:
      res = uvc_get_scanning_mode(devh, &v8u, req_code);
      if (res == UVC_SUCCESS) *out_value = (int32_t)v8u;
      break;
    case UVC_CTRL_ID_BRIGHTNESS:
      res = uvc_get_brightness(devh, &v16s, req_code);
      if (res == UVC_SUCCESS) *out_value = (int32_t)v16s;
      break;
    case UVC_CTRL_ID_CONTRAST:
      res = uvc_get_contrast(devh, &v16u, req_code);
      if (res == UVC_SUCCESS) *out_value = (int32_t)v16u;
      break;
    case UVC_CTRL_ID_HUE:
      res = uvc_get_hue(devh, &v16s, req_code);
      if (res == UVC_SUCCESS) *out_value = (int32_t)v16s;
      break;
    case UVC_CTRL_ID_SATURATION:
      res = uvc_get_saturation(devh, &v16u, req_code);
      if (res == UVC_SUCCESS) *out_value = (int32_t)v16u;
      break;
    case UVC_CTRL_ID_SHARPNESS:
      res = uvc_get_sharpness(devh, &v16u, req_code);
      if (res == UVC_SUCCESS) *out_value = (int32_t)v16u;
      break;
    case UVC_CTRL_ID_GAMMA:
      res = uvc_get_gamma(devh, &v16u, req_code);
      if (res == UVC_SUCCESS) *out_value = (int32_t)v16u;
      break;
    case UVC_CTRL_ID_GAIN:
      res = uvc_get_gain(devh, &v16u, req_code);
      if (res == UVC_SUCCESS) *out_value = (int32_t)v16u;
      break;
    case UVC_CTRL_ID_BACKLIGHT_COMPENSATION:
      res = uvc_get_backlight_compensation(devh, &v16u, req_code);
      if (res == UVC_SUCCESS) *out_value = (int32_t)v16u;
      break;
    case UVC_CTRL_ID_WHITE_BALANCE_TEMPERATURE:
      res = uvc_get_white_balance_temperature(devh, &v16u, req_code);
      if (res == UVC_SUCCESS) *out_value = (int32_t)v16u;
      break;
    case UVC_CTRL_ID_WHITE_BALANCE_TEMP_AUTO:
      res = uvc_get_white_balance_temperature_auto(devh, &v8u, req_code);
      if (res == UVC_SUCCESS) *out_value = (int32_t)v8u;
      break;
    case UVC_CTRL_ID_POWER_LINE_FREQUENCY:
      res = uvc_get_power_line_frequency(devh, &v8u, req_code);
      if (res == UVC_SUCCESS) *out_value = (int32_t)v8u;
      break;
    case UVC_CTRL_ID_CONTRAST_AUTO:
      res = uvc_get_contrast_auto(devh, &v8u, req_code);
      if (res == UVC_SUCCESS) *out_value = (int32_t)v8u;
      break;
    case UVC_CTRL_ID_HUE_AUTO:
      res = uvc_get_hue_auto(devh, &v8u, req_code);
      if (res == UVC_SUCCESS) *out_value = (int32_t)v8u;
      break;
    case UVC_CTRL_ID_EXPOSURE_ABS:
      res = uvc_get_exposure_abs(devh, &v32u, req_code);
      if (res == UVC_SUCCESS) *out_value = (int32_t)v32u;
      break;
    case UVC_CTRL_ID_EXPOSURE_REL:
      res = uvc_get_exposure_rel(devh, &v8s, req_code);
      if (res == UVC_SUCCESS) *out_value = (int32_t)v8s;
      break;
    case UVC_CTRL_ID_AE_MODE:
      res = uvc_get_ae_mode(devh, &v8u, req_code);
      if (res == UVC_SUCCESS) *out_value = (int32_t)v8u;
      break;
    case UVC_CTRL_ID_AE_PRIORITY:
      res = uvc_get_ae_priority(devh, &v8u, req_code);
      if (res == UVC_SUCCESS) *out_value = (int32_t)v8u;
      break;
    case UVC_CTRL_ID_FOCUS_ABS:
      res = uvc_get_focus_abs(devh, &v16u, req_code);
      if (res == UVC_SUCCESS) *out_value = (int32_t)v16u;
      break;
    case UVC_CTRL_ID_FOCUS_AUTO:
      res = uvc_get_focus_auto(devh, &v8u, req_code);
      if (res == UVC_SUCCESS) *out_value = (int32_t)v8u;
      break;
    case UVC_CTRL_ID_IRIS_ABS:
      res = uvc_get_iris_abs(devh, &v16u, req_code);
      if (res == UVC_SUCCESS) *out_value = (int32_t)v16u;
      break;
    case UVC_CTRL_ID_IRIS_REL:
      res = uvc_get_iris_rel(devh, &v8u, req_code);
      if (res == UVC_SUCCESS) *out_value = (int32_t)v8u;
      break;
    case UVC_CTRL_ID_ZOOM_ABS:
      res = uvc_get_zoom_abs(devh, &v16u, req_code);
      if (res == UVC_SUCCESS) *out_value = (int32_t)v16u;
      break;
    case UVC_CTRL_ID_ROLL_ABS:
      res = uvc_get_roll_abs(devh, &v16s, req_code);
      if (res == UVC_SUCCESS) *out_value = (int32_t)v16s;
      break;
    case UVC_CTRL_ID_PRIVACY:
      res = uvc_get_privacy(devh, &v8u, req_code);
      if (res == UVC_SUCCESS) *out_value = (int32_t)v8u;
      break;
    case UVC_CTRL_ID_FOCUS_SIMPLE:
      res = uvc_get_focus_simple_range(devh, &v8u, req_code);
      if (res == UVC_SUCCESS) *out_value = (int32_t)v8u;
      break;
    case UVC_CTRL_ID_WHITE_BALANCE_COMPONENT_AUTO:
      res = uvc_get_white_balance_component_auto(devh, &v8u, req_code);
      if (res == UVC_SUCCESS) *out_value = (int32_t)v8u;
      break;
    case UVC_CTRL_ID_DIGITAL_MULTIPLIER:
      res = uvc_get_digital_multiplier(devh, &v16u, req_code);
      if (res == UVC_SUCCESS) *out_value = (int32_t)v16u;
      break;
    case UVC_CTRL_ID_DIGITAL_MULTIPLIER_LIMIT:
      res = uvc_get_digital_multiplier_limit(devh, &v16u, req_code);
      if (res == UVC_SUCCESS) *out_value = (int32_t)v16u;
      break;
    case UVC_CTRL_ID_ANALOG_VIDEO_STANDARD:
      res = uvc_get_analog_video_standard(devh, &v8u, req_code);
      if (res == UVC_SUCCESS) *out_value = (int32_t)v8u;
      break;
    case UVC_CTRL_ID_ANALOG_LOCK_STATUS:
      res = uvc_get_analog_video_lock_status(devh, &v8u, req_code);
      if (res == UVC_SUCCESS) *out_value = (int32_t)v8u;
      break;
    default:
      UVC_LOGD(
          "UVC_NATIVE",
          "ctrl request unsupported id=%d name=%s req=%s",
          ctrl_id,
          ctrl_name,
          uvc_req_code_name(req_code));
      return 0;
  }

  if (res == UVC_SUCCESS) {
    UVC_LOGD(
        "UVC_NATIVE",
        "ctrl request end id=%d name=%s req=%s ok value=%d",
        ctrl_id,
        ctrl_name,
        uvc_req_code_name(req_code),
        (int)*out_value);
  } else {
    UVC_LOGD(
        "UVC_NATIVE",
        "ctrl request end id=%d name=%s req=%s err=%d",
        ctrl_id,
        ctrl_name,
        uvc_req_code_name(req_code),
        (int)res);
  }

  return (res == UVC_SUCCESS) ? 1 : 0;
}

static int ctrl_set_raw(uvc_device_handle_t *devh, int ctrl_id, int32_t value) {
  uvc_error_t res = UVC_ERROR_NOT_SUPPORTED;

  switch (ctrl_id) {
    case UVC_CTRL_ID_SCANNING_MODE:
      res = uvc_set_scanning_mode(devh, (uint8_t)value);
      break;
    case UVC_CTRL_ID_BRIGHTNESS:
      res = uvc_set_brightness(devh, (int16_t)value);
      break;
    case UVC_CTRL_ID_CONTRAST:
      res = uvc_set_contrast(devh, (uint16_t)value);
      break;
    case UVC_CTRL_ID_HUE:
      res = uvc_set_hue(devh, (int16_t)value);
      break;
    case UVC_CTRL_ID_SATURATION:
      res = uvc_set_saturation(devh, (uint16_t)value);
      break;
    case UVC_CTRL_ID_SHARPNESS:
      res = uvc_set_sharpness(devh, (uint16_t)value);
      break;
    case UVC_CTRL_ID_GAMMA:
      res = uvc_set_gamma(devh, (uint16_t)value);
      break;
    case UVC_CTRL_ID_GAIN:
      res = uvc_set_gain(devh, (uint16_t)value);
      break;
    case UVC_CTRL_ID_BACKLIGHT_COMPENSATION:
      res = uvc_set_backlight_compensation(devh, (uint16_t)value);
      break;
    case UVC_CTRL_ID_WHITE_BALANCE_TEMPERATURE:
      res = uvc_set_white_balance_temperature(devh, (uint16_t)value);
      break;
    case UVC_CTRL_ID_WHITE_BALANCE_TEMP_AUTO:
      res = uvc_set_white_balance_temperature_auto(devh, (uint8_t)value);
      break;
    case UVC_CTRL_ID_POWER_LINE_FREQUENCY:
      res = uvc_set_power_line_frequency(devh, (uint8_t)value);
      break;
    case UVC_CTRL_ID_CONTRAST_AUTO:
      res = uvc_set_contrast_auto(devh, (uint8_t)value);
      break;
    case UVC_CTRL_ID_HUE_AUTO:
      res = uvc_set_hue_auto(devh, (uint8_t)value);
      break;
    case UVC_CTRL_ID_EXPOSURE_ABS:
      res = uvc_set_exposure_abs(devh, (uint32_t)value);
      break;
    case UVC_CTRL_ID_EXPOSURE_REL:
      res = uvc_set_exposure_rel(devh, (int8_t)value);
      break;
    case UVC_CTRL_ID_AE_MODE:
      res = uvc_set_ae_mode(devh, (uint8_t)value);
      break;
    case UVC_CTRL_ID_AE_PRIORITY:
      res = uvc_set_ae_priority(devh, (uint8_t)value);
      break;
    case UVC_CTRL_ID_FOCUS_ABS:
      res = uvc_set_focus_abs(devh, (uint16_t)value);
      break;
    case UVC_CTRL_ID_FOCUS_AUTO:
      res = uvc_set_focus_auto(devh, (uint8_t)value);
      break;
    case UVC_CTRL_ID_IRIS_ABS:
      res = uvc_set_iris_abs(devh, (uint16_t)value);
      break;
    case UVC_CTRL_ID_IRIS_REL:
      res = uvc_set_iris_rel(devh, (uint8_t)value);
      break;
    case UVC_CTRL_ID_ZOOM_ABS:
      res = uvc_set_zoom_abs(devh, (uint16_t)value);
      break;
    case UVC_CTRL_ID_ROLL_ABS:
      res = uvc_set_roll_abs(devh, (int16_t)value);
      break;
    case UVC_CTRL_ID_PRIVACY:
      res = uvc_set_privacy(devh, (uint8_t)value);
      break;
    case UVC_CTRL_ID_FOCUS_SIMPLE:
      res = uvc_set_focus_simple_range(devh, (uint8_t)value);
      break;
    case UVC_CTRL_ID_WHITE_BALANCE_COMPONENT_AUTO:
      res = uvc_set_white_balance_component_auto(devh, (uint8_t)value);
      break;
    case UVC_CTRL_ID_DIGITAL_MULTIPLIER:
      res = uvc_set_digital_multiplier(devh, (uint16_t)value);
      break;
    case UVC_CTRL_ID_DIGITAL_MULTIPLIER_LIMIT:
      res = uvc_set_digital_multiplier_limit(devh, (uint16_t)value);
      break;
    case UVC_CTRL_ID_ANALOG_VIDEO_STANDARD:
      res = uvc_set_analog_video_standard(devh, (uint8_t)value);
      break;
    case UVC_CTRL_ID_ANALOG_LOCK_STATUS:
      res = uvc_set_analog_video_lock_status(devh, (uint8_t)value);
      break;
    default:
      return UVC_ERROR_NOT_SUPPORTED;
  }

  return (int)res;
}

// Reads bmControls bitmaps from the cached descriptors and probes every
// advertised control. Caller holds usb_mutex.
static int ctrl_get_all_json_usb_locked(uvc_device_handle_t *devh, uint8_t *buffer, int buffer_length) {
  // Read bmControls bitmaps from descriptors — no USB transfer needed.
  // Bit position = UVC selector value - 1.
  uint64_t ct_bm = 0;
  uint64_t pu_bm = 0;

  const uvc_input_terminal_t *ct = uvc_get_camera_terminal(devh);
  if (ct != NULL) {
    ct_bm = ct->bmControls;
  }

  const uvc_processing_unit_t *pu = uvc_get_processing_units(devh);
  if (pu != NULL) {
    pu_bm = pu->bmControls;
  }

  UVC_LOGD("UVC_NATIVE", "bmControls ct=0x%llx pu=0x%llx",
           (unsigned long long)ct_bm, (unsigned long long)pu_bm);

  char *json = (char *)buffer;
  size_t offset = 0;
  int first = 1;

  if (!append_json(json, (size_t)buffer_length, &offset, "[")) {
    return 0;
  }

  for (int i = 0; i < k_ctrl_table_size; ++i) {
    const ctrl_info_t *info = &k_ctrl_table[i];

    // Check bmControls before touching USB — avoids timeout on unsupported controls.
    uint64_t bm = info->is_ct ? ct_bm : pu_bm;
    if (!(bm & (1ULL << info->bm_bit))) {
      UVC_LOGD("UVC_NATIVE", "ctrl id=%d name=%s not in bmControls, skip", info->id, info->name);
      continue;
    }

    int32_t cur = 0, min_val = 0, max_val = 0, def_val = 0, res_val = 1;
    if (!ctrl_get_raw(devh, info->id, UVC_GET_CUR, &cur)) {
      UVC_LOGD("UVC_NATIVE", "ctrl id=%d name=%s bmControls bit set but GET_CUR failed", info->id, info->name);
      continue;
    }
    ctrl_get_raw(devh, info->id, UVC_GET_MIN, &min_val);
    ctrl_get_raw(devh, info->id, UVC_GET_MAX, &max_val);
    ctrl_get_raw(devh, info->id, UVC_GET_DEF, &def_val);
    ctrl_get_raw(devh, info->id, UVC_GET_RES, &res_val);
    if (res_val <= 0) res_val = 1;

    if (!append_json(
            json, (size_t)buffer_length, &offset,
            "%s{\"id\":%d,\"name\":\"%s\",\"label\":\"%s\","
            "\"uiType\":\"%s\",\"min\":%d,\"max\":%d,"
            "\"def\":%d,\"cur\":%d,\"res\":%d}",
            first ? "" : ",",
            info->id, info->name, info->label,
            info->ui_type,
            min_val, max_val, def_val, cur, res_val)) {
      return 0;
    }
    first = 0;
    UVC_LOGD(
        "UVC_NATIVE",
        "ctrl id=%d name=%s cur=%d min=%d max=%d def=%d res=%d",
        info->id, info->name, cur, min_val, max_val, def_val, res_val);
  }

  if (!append_json(json, (size_t)buffer_length, &offset, "]")) {
    return 0;
  }

  return (int)offset;
}

FFI_PLUGIN_EXPORT int uvc_ctrl_get_all_json(uvc_session_t *s, uint8_t *buffer, int buffer_length) {
  if (s == NULL || buffer == NULL || buffer_length <= 0) {
    return 0;
  }

  pthread_mutex_lock(&s->usb_mutex);
  uvc_device_handle_t *devh = s->devh;
  if (devh == NULL) {
    pthread_mutex_unlock(&s->usb_mutex);
    return 0;
  }
  const int written = ctrl_get_all_json_usb_locked(devh, buffer, buffer_length);
  pthread_mutex_unlock(&s->usb_mutex);
  return written;
}

// Descriptor-only listing with no USB traffic. Caller holds usb_mutex.
static int ctrl_get_bm_controls_json_usb_locked(uvc_device_handle_t *devh, uint8_t *buffer, int buffer_length) {
  uint64_t ct_bm = 0;
  uint64_t pu_bm = 0;

  const uvc_input_terminal_t *ct = uvc_get_camera_terminal(devh);
  if (ct != NULL) {
    ct_bm = ct->bmControls;
  }

  const uvc_processing_unit_t *pu = uvc_get_processing_units(devh);
  if (pu != NULL) {
    pu_bm = pu->bmControls;
  }

  UVC_LOGD("UVC_NATIVE", "bmControls-only ct=0x%llx pu=0x%llx",
           (unsigned long long)ct_bm, (unsigned long long)pu_bm);

  char *json = (char *)buffer;
  size_t offset = 0;
  int first = 1;

  if (!append_json(json, (size_t)buffer_length, &offset, "[")) {
    return 0;
  }

  for (int i = 0; i < k_ctrl_table_size; ++i) {
    const ctrl_info_t *info = &k_ctrl_table[i];
    uint64_t bm = info->is_ct ? ct_bm : pu_bm;
    if (!(bm & (1ULL << info->bm_bit))) {
      continue;
    }

    if (!append_json(
            json, (size_t)buffer_length, &offset,
            "%s{\"id\":%d,\"name\":\"%s\",\"label\":\"%s\",\"uiType\":\"%s\"}",
            first ? "" : ",",
            info->id, info->name, info->label, info->ui_type)) {
      return 0;
    }
    first = 0;
  }

  if (!append_json(json, (size_t)buffer_length, &offset, "]")) {
    return 0;
  }

  return (int)offset;
}

FFI_PLUGIN_EXPORT int uvc_ctrl_get_bm_controls_json(uvc_session_t *s, uint8_t *buffer, int buffer_length) {
  if (s == NULL || buffer == NULL || buffer_length <= 0) {
    return 0;
  }

  pthread_mutex_lock(&s->usb_mutex);
  uvc_device_handle_t *devh = s->devh;
  if (devh == NULL) {
    pthread_mutex_unlock(&s->usb_mutex);
    return 0;
  }
  const int written = ctrl_get_bm_controls_json_usb_locked(devh, buffer, buffer_length);
  pthread_mutex_unlock(&s->usb_mutex);
  return written;
}

FFI_PLUGIN_EXPORT int32_t uvc_ctrl_get(uvc_session_t *s, int ctrl_id) {
  if (s == NULL) {
    return INT32_MIN;
  }

  pthread_mutex_lock(&s->usb_mutex);
  uvc_device_handle_t *devh = s->devh;
  if (devh == NULL) {
    pthread_mutex_unlock(&s->usb_mutex);
    return INT32_MIN;
  }

  int32_t value = 0;
  int ok = ctrl_get_raw(devh, ctrl_id, UVC_GET_CUR, &value);
  pthread_mutex_unlock(&s->usb_mutex);
  return ok ? value : INT32_MIN;
}

FFI_PLUGIN_EXPORT int uvc_ctrl_set(uvc_session_t *s, int ctrl_id, int32_t value) {
  if (s == NULL) {
    return UVC_ERROR_INVALID_PARAM;
  }

  pthread_mutex_lock(&s->usb_mutex);
  uvc_device_handle_t *devh = s->devh;
  if (devh == NULL) {
    pthread_mutex_unlock(&s->usb_mutex);
    set_last_error(s, "Camera is not open");
    return UVC_ERROR_NO_DEVICE;
  }

  int result = ctrl_set_raw(devh, ctrl_id, value);
  pthread_mutex_unlock(&s->usb_mutex);
  if (result != UVC_SUCCESS) {
    set_last_error(s, "uvc_ctrl_set failed ctrl_id=%d value=%d err=%d", ctrl_id, value, result);
    UVC_LOGW("UVC_NATIVE", "uvc_ctrl_set failed ctrl_id=%d value=%d err=%d", ctrl_id, value, result);
  }
  return result;
}

// Takes usb_mutex and hands out the open device handle. On UVC_SUCCESS the
// caller owns usb_mutex until release_open_device. On error nothing is held.
static int acquire_open_device(uvc_session_t *s, uvc_device_handle_t **out_devh) {
  if (s == NULL) {
    return UVC_ERROR_INVALID_PARAM;
  }

  pthread_mutex_lock(&s->usb_mutex);
  uvc_device_handle_t *devh = s->devh;
  if (devh == NULL) {
    pthread_mutex_unlock(&s->usb_mutex);
    set_last_error(s, "Camera is not open");
    return UVC_ERROR_NO_DEVICE;
  }

  *out_devh = devh;
  return UVC_SUCCESS;
}

static void release_open_device(uvc_session_t *s) {
  pthread_mutex_unlock(&s->usb_mutex);
}

static int write_json_payload(uint8_t *buffer, int buffer_length, const char *format, ...) {
  if (buffer == NULL || buffer_length <= 0) {
    return 0;
  }

  va_list args;
  va_start(args, format);
  const int written = vsnprintf((char *)buffer, (size_t)buffer_length, format, args);
  va_end(args);

  if (written < 0 || written >= buffer_length) {
    return 0;
  }

  return written;
}

FFI_PLUGIN_EXPORT int uvc_get_white_balance_component_json(uvc_session_t *s, uint8_t *buffer, int buffer_length) {
  uvc_device_handle_t *devh = NULL;
  uint16_t blue = 0;
  uint16_t red = 0;
  if (acquire_open_device(s, &devh) != UVC_SUCCESS) return 0;
  const uvc_error_t res = uvc_get_white_balance_component(devh, &blue, &red, UVC_GET_CUR);
  release_open_device(s);
  if (res != UVC_SUCCESS) return 0;
  return write_json_payload(buffer, buffer_length, "{\"blue\":%u,\"red\":%u}", blue, red);
}

FFI_PLUGIN_EXPORT int uvc_set_white_balance_component_values(uvc_session_t *s, uint16_t blue, uint16_t red) {
  uvc_device_handle_t *devh = NULL;
  const int acquired = acquire_open_device(s, &devh);
  if (acquired != UVC_SUCCESS) return acquired;
  const int result = (int)uvc_set_white_balance_component(devh, blue, red);
  release_open_device(s);
  return result;
}

FFI_PLUGIN_EXPORT int uvc_get_focus_rel_json(uvc_session_t *s, uint8_t *buffer, int buffer_length) {
  uvc_device_handle_t *devh = NULL;
  int8_t focus_rel = 0;
  uint8_t speed = 0;
  if (acquire_open_device(s, &devh) != UVC_SUCCESS) return 0;
  const uvc_error_t res = uvc_get_focus_rel(devh, &focus_rel, &speed, UVC_GET_CUR);
  release_open_device(s);
  if (res != UVC_SUCCESS) return 0;
  return write_json_payload(
      buffer,
      buffer_length,
      "{\"focusRel\":%d,\"speed\":%u}",
      (int)focus_rel,
      speed);
}

FFI_PLUGIN_EXPORT int uvc_set_focus_rel_values(uvc_session_t *s, int8_t focus_rel, uint8_t speed) {
  uvc_device_handle_t *devh = NULL;
  const int acquired = acquire_open_device(s, &devh);
  if (acquired != UVC_SUCCESS) return acquired;
  const int result = (int)uvc_set_focus_rel(devh, focus_rel, speed);
  release_open_device(s);
  return result;
}

FFI_PLUGIN_EXPORT int uvc_get_zoom_rel_json(uvc_session_t *s, uint8_t *buffer, int buffer_length) {
  uvc_device_handle_t *devh = NULL;
  int8_t zoom_rel = 0;
  uint8_t digital_zoom = 0;
  uint8_t speed = 0;
  if (acquire_open_device(s, &devh) != UVC_SUCCESS) return 0;
  const uvc_error_t res = uvc_get_zoom_rel(devh, &zoom_rel, &digital_zoom, &speed, UVC_GET_CUR);
  release_open_device(s);
  if (res != UVC_SUCCESS) return 0;
  return write_json_payload(
      buffer,
      buffer_length,
      "{\"zoomRel\":%d,\"digitalZoom\":%u,\"speed\":%u}",
      (int)zoom_rel,
      digital_zoom,
      speed);
}

FFI_PLUGIN_EXPORT int uvc_set_zoom_rel_values(uvc_session_t *s, int8_t zoom_rel, uint8_t digital_zoom, uint8_t speed) {
  uvc_device_handle_t *devh = NULL;
  const int acquired = acquire_open_device(s, &devh);
  if (acquired != UVC_SUCCESS) return acquired;
  const int result = (int)uvc_set_zoom_rel(devh, zoom_rel, digital_zoom, speed);
  release_open_device(s);
  return result;
}

FFI_PLUGIN_EXPORT int uvc_get_pantilt_abs_json(uvc_session_t *s, uint8_t *buffer, int buffer_length) {
  uvc_device_handle_t *devh = NULL;
  int32_t pan = 0;
  int32_t tilt = 0;
  if (acquire_open_device(s, &devh) != UVC_SUCCESS) return 0;
  const uvc_error_t res = uvc_get_pantilt_abs(devh, &pan, &tilt, UVC_GET_CUR);
  release_open_device(s);
  if (res != UVC_SUCCESS) return 0;
  return write_json_payload(buffer, buffer_length, "{\"pan\":%d,\"tilt\":%d}", pan, tilt);
}

FFI_PLUGIN_EXPORT int uvc_set_pantilt_abs_values(uvc_session_t *s, int32_t pan, int32_t tilt) {
  uvc_device_handle_t *devh = NULL;
  const int acquired = acquire_open_device(s, &devh);
  if (acquired != UVC_SUCCESS) return acquired;
  const int result = (int)uvc_set_pantilt_abs(devh, pan, tilt);
  release_open_device(s);
  return result;
}

FFI_PLUGIN_EXPORT int uvc_get_pantilt_rel_json(uvc_session_t *s, uint8_t *buffer, int buffer_length) {
  uvc_device_handle_t *devh = NULL;
  int8_t pan_rel = 0;
  uint8_t pan_speed = 0;
  int8_t tilt_rel = 0;
  uint8_t tilt_speed = 0;
  if (acquire_open_device(s, &devh) != UVC_SUCCESS) return 0;
  const uvc_error_t res = uvc_get_pantilt_rel(devh, &pan_rel, &pan_speed, &tilt_rel, &tilt_speed, UVC_GET_CUR);
  release_open_device(s);
  if (res != UVC_SUCCESS) return 0;
  return write_json_payload(
      buffer,
      buffer_length,
      "{\"panRel\":%d,\"panSpeed\":%u,\"tiltRel\":%d,\"tiltSpeed\":%u}",
      (int)pan_rel,
      pan_speed,
      (int)tilt_rel,
      tilt_speed);
}

FFI_PLUGIN_EXPORT int uvc_set_pantilt_rel_values(uvc_session_t *s, int8_t pan_rel, uint8_t pan_speed, int8_t tilt_rel, uint8_t tilt_speed) {
  uvc_device_handle_t *devh = NULL;
  const int acquired = acquire_open_device(s, &devh);
  if (acquired != UVC_SUCCESS) return acquired;
  const int result = (int)uvc_set_pantilt_rel(devh, pan_rel, pan_speed, tilt_rel, tilt_speed);
  release_open_device(s);
  return result;
}

FFI_PLUGIN_EXPORT int uvc_get_roll_rel_json(uvc_session_t *s, uint8_t *buffer, int buffer_length) {
  uvc_device_handle_t *devh = NULL;
  int8_t roll_rel = 0;
  uint8_t speed = 0;
  if (acquire_open_device(s, &devh) != UVC_SUCCESS) return 0;
  const uvc_error_t res = uvc_get_roll_rel(devh, &roll_rel, &speed, UVC_GET_CUR);
  release_open_device(s);
  if (res != UVC_SUCCESS) return 0;
  return write_json_payload(
      buffer,
      buffer_length,
      "{\"rollRel\":%d,\"speed\":%u}",
      (int)roll_rel,
      speed);
}

FFI_PLUGIN_EXPORT int uvc_set_roll_rel_values(uvc_session_t *s, int8_t roll_rel, uint8_t speed) {
  uvc_device_handle_t *devh = NULL;
  const int acquired = acquire_open_device(s, &devh);
  if (acquired != UVC_SUCCESS) return acquired;
  const int result = (int)uvc_set_roll_rel(devh, roll_rel, speed);
  release_open_device(s);
  return result;
}

FFI_PLUGIN_EXPORT int uvc_get_digital_window_json(uvc_session_t *s, uint8_t *buffer, int buffer_length) {
  uvc_device_handle_t *devh = NULL;
  uint16_t top = 0;
  uint16_t left = 0;
  uint16_t bottom = 0;
  uint16_t right = 0;
  uint16_t num_steps = 0;
  uint16_t num_steps_units = 0;
  if (acquire_open_device(s, &devh) != UVC_SUCCESS) return 0;
  const uvc_error_t res = uvc_get_digital_window(
      devh,
      &top,
      &left,
      &bottom,
      &right,
      &num_steps,
      &num_steps_units,
      UVC_GET_CUR);
  release_open_device(s);
  if (res != UVC_SUCCESS) {
    return 0;
  }
  return write_json_payload(
      buffer,
      buffer_length,
      "{\"windowTop\":%u,\"windowLeft\":%u,\"windowBottom\":%u,"
      "\"windowRight\":%u,\"numSteps\":%u,\"numStepsUnits\":%u}",
      top,
      left,
      bottom,
      right,
      num_steps,
      num_steps_units);
}

FFI_PLUGIN_EXPORT int uvc_set_digital_window_values(
    uvc_session_t *s,
    uint16_t window_top,
    uint16_t window_left,
    uint16_t window_bottom,
    uint16_t window_right,
    uint16_t num_steps,
    uint16_t num_steps_units) {
  uvc_device_handle_t *devh = NULL;
  const int acquired = acquire_open_device(s, &devh);
  if (acquired != UVC_SUCCESS) return acquired;
  const int result = (int)uvc_set_digital_window(
      devh,
      window_top,
      window_left,
      window_bottom,
      window_right,
      num_steps,
      num_steps_units);
  release_open_device(s);
  return result;
}

FFI_PLUGIN_EXPORT int uvc_get_region_of_interest_json(uvc_session_t *s, uint8_t *buffer, int buffer_length) {
  uvc_device_handle_t *devh = NULL;
  uint16_t top = 0;
  uint16_t left = 0;
  uint16_t bottom = 0;
  uint16_t right = 0;
  uint16_t auto_controls = 0;
  if (acquire_open_device(s, &devh) != UVC_SUCCESS) return 0;
  const uvc_error_t res = uvc_get_digital_roi(
      devh,
      &top,
      &left,
      &bottom,
      &right,
      &auto_controls,
      UVC_GET_CUR);
  release_open_device(s);
  if (res != UVC_SUCCESS) {
    return 0;
  }
  return write_json_payload(
      buffer,
      buffer_length,
      "{\"roiTop\":%u,\"roiLeft\":%u,\"roiBottom\":%u,"
      "\"roiRight\":%u,\"autoControls\":%u}",
      top,
      left,
      bottom,
      right,
      auto_controls);
}

FFI_PLUGIN_EXPORT int uvc_set_region_of_interest_values(
    uvc_session_t *s,
    uint16_t roi_top,
    uint16_t roi_left,
    uint16_t roi_bottom,
    uint16_t roi_right,
    uint16_t auto_controls) {
  uvc_device_handle_t *devh = NULL;
  const int acquired = acquire_open_device(s, &devh);
  if (acquired != UVC_SUCCESS) return acquired;
  const int result = (int)uvc_set_digital_roi(
      devh,
      roi_top,
      roi_left,
      roi_bottom,
      roi_right,
      auto_controls);
  release_open_device(s);
  return result;
}
