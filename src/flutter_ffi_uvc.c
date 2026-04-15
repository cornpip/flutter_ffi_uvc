#include "flutter_ffi_uvc.h"

#include <stdarg.h>
#include <stdio.h>
#include <string.h>

#include "libuvc/libuvc.h"
#include "libuvc/uvc_log.h"

int g_uvc_native_log_level = UVC_LOG_LEVEL_DEFAULT;

// libuvc only exposes this declaration when libusb version macros are visible.
uvc_error_t uvc_wrap(int sys_dev, uvc_context_t *context, uvc_device_handle_t **devh);

typedef struct {
  pthread_mutex_t mutex;
  pthread_cond_t callback_cond;
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
  uvc_frame_listener_t frame_listener;
  uint32_t callback_count;
  uint32_t mjpeg_warmup_drop_remaining;
  char last_error[256];
} ffi_uvc_state_t;

static ffi_uvc_state_t g_uvc_state = {
    .mutex = PTHREAD_MUTEX_INITIALIZER,
    .callback_cond = PTHREAD_COND_INITIALIZER,
};

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

static void set_last_error(const char *format, ...) {
  va_list args;
  va_start(args, format);
  vsnprintf(g_uvc_state.last_error, sizeof(g_uvc_state.last_error), format, args);
  va_end(args);
}

static void clear_last_error(void) {
  g_uvc_state.last_error[0] = '\0';
}


static void reset_frame_buffer_locked(void) {
  free(g_uvc_state.latest_rgba);
  g_uvc_state.latest_rgba = NULL;
  g_uvc_state.latest_rgba_bytes = 0;
  g_uvc_state.frame_width = 0;
  g_uvc_state.frame_height = 0;
  g_uvc_state.latest_sequence = 0;
  g_uvc_state.callback_count = 0;
}

static void finish_callback_locked(void) {
  if (g_uvc_state.callbacks_inflight == 0) {
    return;
  }

  g_uvc_state.callbacks_inflight -= 1;
  if (g_uvc_state.callbacks_inflight == 0) {
    pthread_cond_broadcast(&g_uvc_state.callback_cond);
  }
}

static void wait_for_callbacks_locked(void) {
  while (g_uvc_state.callbacks_inflight > 0) {
    pthread_cond_wait(&g_uvc_state.callback_cond, &g_uvc_state.mutex);
  }
}

static int begin_stop_preview_locked(uvc_device_handle_t **devh_to_stop) {
  if (g_uvc_state.previewing && g_uvc_state.devh != NULL) {
    *devh_to_stop = g_uvc_state.devh;
    g_uvc_state.previewing = 0;
    g_uvc_state.stopping_preview = 1;
    g_uvc_state.frame_listener = NULL;
    return 1;
  }

  g_uvc_state.frame_listener = NULL;
  return 0;
}

static void finish_stop_preview_locked(void) {
  wait_for_callbacks_locked();
  reset_frame_buffer_locked();
  g_uvc_state.stopping_preview = 0;
}

static void close_device_resources_locked(void) {

  if (g_uvc_state.rgb_frame != NULL) {
    UVC_LOGD("UVC_NATIVE", "close_device_resources_locked freeing rgb_frame=%p", (void *)g_uvc_state.rgb_frame);
    uvc_free_frame(g_uvc_state.rgb_frame);
    g_uvc_state.rgb_frame = NULL;
  }

  if (g_uvc_state.devh != NULL) {
    UVC_LOGD("UVC_NATIVE", "close_device_resources_locked closing device handle devh=%p", (void *)g_uvc_state.devh);
    uvc_close(g_uvc_state.devh);
    g_uvc_state.devh = NULL;
  }

  if (g_uvc_state.ctx != NULL) {
    UVC_LOGD("UVC_NATIVE", "close_device_resources_locked exiting uvc context ctx=%p", (void *)g_uvc_state.ctx);
    uvc_exit(g_uvc_state.ctx);
    g_uvc_state.ctx = NULL;
  }

  UVC_LOGD("UVC_NATIVE", "close_device_resources_locked resetting frame buffers");
  reset_frame_buffer_locked();
  g_uvc_state.previewing = 0;
  g_uvc_state.stopping_preview = 0;
  g_uvc_state.frame_listener = NULL;
}

static int ensure_rgb_frame_locked(size_t required_bytes) {
  if (required_bytes == 0) {
    set_last_error("Invalid RGB frame size: %zu", required_bytes);
    return 0;
  }

  if (g_uvc_state.rgb_frame == NULL) {
    g_uvc_state.rgb_frame = uvc_allocate_frame(required_bytes);
    if (g_uvc_state.rgb_frame == NULL) {
      set_last_error("Failed to allocate RGB frame buffer (%zu bytes)", required_bytes);
      return 0;
    }
    return 1;
  }

  if (g_uvc_state.rgb_frame->data_bytes < required_bytes) {
    uint8_t *new_data = realloc(g_uvc_state.rgb_frame->data, required_bytes);
    if (new_data == NULL) {
      set_last_error("Failed to grow RGB frame buffer to %zu bytes", required_bytes);
      return 0;
    }
    g_uvc_state.rgb_frame->data = new_data;
    g_uvc_state.rgb_frame->data_bytes = required_bytes;
  }

  return 1;
}

static int update_latest_rgba_locked(void) {
  const size_t rgba_bytes = (size_t)g_uvc_state.rgb_frame->width * (size_t)g_uvc_state.rgb_frame->height * 4;

  if (g_uvc_state.latest_rgba_bytes != rgba_bytes) {
    uint8_t *new_buffer = realloc(g_uvc_state.latest_rgba, rgba_bytes);
    if (new_buffer == NULL) {
      set_last_error("Failed to allocate %zu bytes for preview frame", rgba_bytes);
      return 0;
    }
    g_uvc_state.latest_rgba = new_buffer;
    g_uvc_state.latest_rgba_bytes = rgba_bytes;
  }

  uint8_t *src = (uint8_t *)g_uvc_state.rgb_frame->data;
  uint8_t *dst = g_uvc_state.latest_rgba;
  const size_t pixel_count =
      (size_t)g_uvc_state.rgb_frame->width * (size_t)g_uvc_state.rgb_frame->height;

  for (size_t i = 0; i < pixel_count; ++i) {
    dst[i * 4 + 0] = src[i * 3 + 0];
    dst[i * 4 + 1] = src[i * 3 + 1];
    dst[i * 4 + 2] = src[i * 3 + 2];
    dst[i * 4 + 3] = 0xFF;
  }

  g_uvc_state.frame_width = g_uvc_state.rgb_frame->width;
  g_uvc_state.frame_height = g_uvc_state.rgb_frame->height;
  g_uvc_state.latest_sequence += 1;
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

static int is_valid_mjpeg_frame(const uvc_frame_t *frame) {
  const uint8_t *data;
  size_t index;

  if (frame == NULL || frame->data == NULL || frame->data_bytes < 4) {
    return 0;
  }

  data = (const uint8_t *)frame->data;
  if (data[0] != 0xFF || data[1] != 0xD8) {
    return 0;
  }

  for (index = frame->data_bytes; index >= 2; --index) {
    if (data[index - 2] == 0xFF && data[index - 1] == 0xD9) {
      return 1;
    }
  }

  return 0;
}

static void frame_callback(uvc_frame_t *frame, void *user_ptr) {
  (void)user_ptr;

  if (frame == NULL || frame->data == NULL) {
    UVC_LOGW("UVC_NATIVE", "frame callback received null frame");
    return;
  }

  pthread_mutex_lock(&g_uvc_state.mutex);
  if (!g_uvc_state.previewing || g_uvc_state.stopping_preview || g_uvc_state.rgb_frame == NULL) {
    pthread_mutex_unlock(&g_uvc_state.mutex);
    UVC_LOGW("UVC_NATIVE", "frame callback skipped because preview is stopping or rgb_frame is null");
    return;
  }
  g_uvc_state.callbacks_inflight += 1;
  g_uvc_state.callback_count += 1;
  uint32_t callback_count = g_uvc_state.callback_count;

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
    set_last_error(
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
    finish_callback_locked();
    pthread_mutex_unlock(&g_uvc_state.mutex);
    return;
  }

  if (frame->frame_format == UVC_FRAME_FORMAT_MJPEG) {
    uint32_t warmup_drop_remaining = g_uvc_state.mjpeg_warmup_drop_remaining;
    if (warmup_drop_remaining > 0) {
      g_uvc_state.mjpeg_warmup_drop_remaining -= 1;
    }

    if (warmup_drop_remaining > 0) {
      UVC_LOGT(
          "UVC_NATIVE",
          "dropping MJPEG warmup frame callback=%u remaining=%u bytes=%zu",
          callback_count,
          warmup_drop_remaining - 1,
          frame->data_bytes);
      finish_callback_locked();
      pthread_mutex_unlock(&g_uvc_state.mutex);
      return;
    }

    if (!is_valid_mjpeg_frame(frame)) {
      set_last_error(
          "Invalid MJPEG frame width=%u height=%u bytes=%zu",
          frame->width,
          frame->height,
          frame->data_bytes);
      UVC_LOGW(
          "UVC_NATIVE",
          "rejecting invalid MJPEG frame callback=%u width=%u height=%u bytes=%zu",
          callback_count,
          frame->width,
          frame->height,
          frame->data_bytes);
      finish_callback_locked();
      pthread_mutex_unlock(&g_uvc_state.mutex);
      return;
    }
  }

  const size_t required_rgb_bytes = (size_t)frame->width * (size_t)frame->height * 3;

  if (!ensure_rgb_frame_locked(required_rgb_bytes)) {
    UVC_LOGE(
        "UVC_NATIVE",
        "frame callback failed to prepare rgb buffer callback=%u width=%u height=%u bytes=%zu",
        callback_count,
        frame->width,
        frame->height,
        required_rgb_bytes);
    finish_callback_locked();
    pthread_mutex_unlock(&g_uvc_state.mutex);
    return;
  }

  uvc_error_t convert_result = uvc_any2rgb(frame, g_uvc_state.rgb_frame);
  if (convert_result != UVC_SUCCESS) {
    set_last_error("uvc_any2rgb failed: %s", uvc_strerror(convert_result));
    UVC_LOGE(
        "UVC_NATIVE",
        "uvc_any2rgb failed callback=%u format=%d width=%u height=%u err=%s",
        callback_count,
        frame->frame_format,
        frame->width,
        frame->height,
        uvc_strerror(convert_result));
    finish_callback_locked();
    pthread_mutex_unlock(&g_uvc_state.mutex);
    return;
  }

  const size_t rgba_bytes = (size_t)g_uvc_state.rgb_frame->width * (size_t)g_uvc_state.rgb_frame->height * 4;
  int64_t delivered_sequence = 0;
  uvc_frame_listener_t frame_listener = NULL;

  if (!update_latest_rgba_locked()) {
    finish_callback_locked();
    pthread_mutex_unlock(&g_uvc_state.mutex);
    return;
  }
  delivered_sequence = g_uvc_state.latest_sequence;
  frame_listener = g_uvc_state.frame_listener;
  clear_last_error();
  finish_callback_locked();
  pthread_mutex_unlock(&g_uvc_state.mutex);

  if (callback_count <= 5 || callback_count % 30 == 0) {
    UVC_LOGT(
        "UVC_NATIVE",
        "frame callback #%u converted rgb width=%d height=%d rgbaBytes=%zu",
        callback_count,
        g_uvc_state.frame_width,
        g_uvc_state.frame_height,
        rgba_bytes);
  }

  if (frame_listener != NULL) {
    frame_listener(delivered_sequence);
  }
}

FFI_PLUGIN_EXPORT int sum(int a, int b) { return a + b; }

FFI_PLUGIN_EXPORT int sum_long_running(int a, int b) {
#if _WIN32
  Sleep(5000);
#else
  usleep(5000 * 1000);
#endif
  return a + b;
}

FFI_PLUGIN_EXPORT int uvc_open_fd(int fd) {
  if (fd < 0) {
    set_last_error("Invalid file descriptor: %d", fd);
    return UVC_ERROR_INVALID_PARAM;
  }

  uvc_device_handle_t *devh_to_stop = NULL;
  int should_stop_streaming = 0;

  pthread_mutex_lock(&g_uvc_state.mutex);
  should_stop_streaming = begin_stop_preview_locked(&devh_to_stop);
  pthread_mutex_unlock(&g_uvc_state.mutex);

  if (should_stop_streaming) {
    uvc_stop_streaming(devh_to_stop);
  }

  pthread_mutex_lock(&g_uvc_state.mutex);
  if (should_stop_streaming) {
    finish_stop_preview_locked();
  }
  close_device_resources_locked();
  clear_last_error();

  uvc_error_t result = uvc_init(&g_uvc_state.ctx, NULL);
  if (result != UVC_SUCCESS) {
    set_last_error("uvc_init failed: %s", uvc_strerror(result));
    close_device_resources_locked();
    pthread_mutex_unlock(&g_uvc_state.mutex);
    return result;
  }

  result = uvc_wrap(fd, g_uvc_state.ctx, &g_uvc_state.devh);
  if (result != UVC_SUCCESS) {
    set_last_error("uvc_wrap failed: %s", uvc_strerror(result));
    close_device_resources_locked();
    pthread_mutex_unlock(&g_uvc_state.mutex);
    return result;
  }

  UVC_LOGI("UVC_NATIVE", "uvc_open_fd success fd=%d", fd);
  uvc_device_t *device = uvc_get_device(g_uvc_state.devh);
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
      (void *)uvc_get_camera_terminal(g_uvc_state.devh),
      (void *)uvc_get_input_terminals(g_uvc_state.devh),
      (void *)uvc_get_processing_units(g_uvc_state.devh),
      (void *)uvc_get_extension_units(g_uvc_state.devh));

  g_uvc_state.rgb_frame = uvc_allocate_frame(1);
  if (g_uvc_state.rgb_frame == NULL) {
    set_last_error("Failed to allocate RGB frame buffer");
    close_device_resources_locked();
    pthread_mutex_unlock(&g_uvc_state.mutex);
    return UVC_ERROR_NO_MEM;
  }

  pthread_mutex_unlock(&g_uvc_state.mutex);
  return UVC_SUCCESS;
}

FFI_PLUGIN_EXPORT int uvc_start_preview(
    int frame_format,
    int width,
    int height,
    int fps) {
  uvc_device_handle_t *devh_to_stop = NULL;
  int should_stop_streaming = 0;

  pthread_mutex_lock(&g_uvc_state.mutex);

  if (g_uvc_state.devh == NULL) {
    set_last_error("Camera is not open");
    pthread_mutex_unlock(&g_uvc_state.mutex);
    return UVC_ERROR_NO_DEVICE;
  }

  should_stop_streaming = begin_stop_preview_locked(&devh_to_stop);
  pthread_mutex_unlock(&g_uvc_state.mutex);

  if (should_stop_streaming) {
    uvc_stop_streaming(devh_to_stop);
  }

  pthread_mutex_lock(&g_uvc_state.mutex);
  if (should_stop_streaming) {
    finish_stop_preview_locked();
  }

  uvc_stream_ctrl_t ctrl;
  memset(&ctrl, 0, sizeof(ctrl));

  const size_t required_rgb_bytes = (size_t)width * (size_t)height * 3;
  if (!ensure_rgb_frame_locked(required_rgb_bytes)) {
    pthread_mutex_unlock(&g_uvc_state.mutex);
    return UVC_ERROR_NO_MEM;
  }

  uvc_error_t result = uvc_get_stream_ctrl_format_size(
      g_uvc_state.devh,
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
    set_last_error("uvc_get_stream_ctrl_format_size failed: %s", uvc_strerror(result));
    pthread_mutex_unlock(&g_uvc_state.mutex);
    return result;
  }

  result = uvc_start_streaming(g_uvc_state.devh, &ctrl, frame_callback, NULL, 0);
  if (result != UVC_SUCCESS) {
    UVC_LOGE("UVC_NATIVE", "uvc_start_streaming failed err=%s", uvc_strerror(result));
    set_last_error("uvc_start_streaming failed: %s", uvc_strerror(result));
    pthread_mutex_unlock(&g_uvc_state.mutex);
    return result;
  }

  g_uvc_state.previewing = 1;
  g_uvc_state.callback_count = 0;
  g_uvc_state.latest_sequence = 0;
  g_uvc_state.mjpeg_warmup_drop_remaining =
      frame_format == UVC_FRAME_FORMAT_MJPEG ? 3 : 0;
  clear_last_error();
  UVC_LOGI(
      "UVC_NATIVE",
      "uvc_start_preview success format=%d width=%d height=%d fps=%d",
      frame_format,
      width,
      height,
      fps);
  pthread_mutex_unlock(&g_uvc_state.mutex);
  return UVC_SUCCESS;
}

FFI_PLUGIN_EXPORT int uvc_get_supported_modes_json(uint8_t *buffer, int buffer_length) {
  if (buffer == NULL || buffer_length <= 0) {
    return 0;
  }

  pthread_mutex_lock(&g_uvc_state.mutex);
  if (g_uvc_state.devh == NULL) {
    UVC_LOGD("UVC_NATIVE", "uvc_get_supported_modes_json called without open device");
    pthread_mutex_unlock(&g_uvc_state.mutex);
    return 0;
  }

  char *json = (char *)buffer;
  size_t offset = 0;
  int first_mode = 1;
  const uvc_format_desc_t *format_desc = uvc_get_format_descs(g_uvc_state.devh);

  if (!append_json(json, (size_t)buffer_length, &offset, "[")) {
    pthread_mutex_unlock(&g_uvc_state.mutex);
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
            pthread_mutex_unlock(&g_uvc_state.mutex);
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
          pthread_mutex_unlock(&g_uvc_state.mutex);
          return 0;
        }
        first_mode = 0;
      }
    }
  }

  if (!append_json(json, (size_t)buffer_length, &offset, "]")) {
    pthread_mutex_unlock(&g_uvc_state.mutex);
    return 0;
  }

  UVC_LOGD("UVC_NATIVE", "supported modes json bytes=%zu", offset);
  pthread_mutex_unlock(&g_uvc_state.mutex);
  return (int)offset;
}

FFI_PLUGIN_EXPORT void uvc_stop_preview(void) {
  uvc_device_handle_t *devh_to_stop = NULL;
  int should_stop_streaming = 0;

  UVC_LOGD("UVC_NATIVE", "uvc_stop_preview begin");
  pthread_mutex_lock(&g_uvc_state.mutex);
  UVC_LOGD(
      "UVC_NATIVE",
      "uvc_stop_preview locked previewing=%d devh=%p",
      g_uvc_state.previewing,
      (void *)g_uvc_state.devh);
  should_stop_streaming = begin_stop_preview_locked(&devh_to_stop);
  pthread_mutex_unlock(&g_uvc_state.mutex);

  if (should_stop_streaming) {
    UVC_LOGD("UVC_NATIVE", "uvc_stop_preview before uvc_stop_streaming");
    uvc_stop_streaming(devh_to_stop);
    UVC_LOGD("UVC_NATIVE", "uvc_stop_preview after uvc_stop_streaming");
  }

  pthread_mutex_lock(&g_uvc_state.mutex);
  finish_stop_preview_locked();
  pthread_mutex_unlock(&g_uvc_state.mutex);
  UVC_LOGD("UVC_NATIVE", "uvc_stop_preview end");
}

FFI_PLUGIN_EXPORT void uvc_close_device(void) {
  uvc_device_handle_t *devh_to_stop = NULL;
  int should_stop_streaming = 0;

  pthread_mutex_lock(&g_uvc_state.mutex);
  UVC_LOGD(
      "UVC_NATIVE",
      "uvc_close_device begin previewing=%d devh=%p ctx=%p",
      g_uvc_state.previewing,
      (void *)g_uvc_state.devh,
      (void *)g_uvc_state.ctx);
  should_stop_streaming = begin_stop_preview_locked(&devh_to_stop);
  pthread_mutex_unlock(&g_uvc_state.mutex);

  if (should_stop_streaming) {
    uvc_stop_streaming(devh_to_stop);
  }

  pthread_mutex_lock(&g_uvc_state.mutex);
  if (should_stop_streaming) {
    finish_stop_preview_locked();
  }
  close_device_resources_locked();
  UVC_LOGI("UVC_NATIVE", "uvc_close_device success");
  UVC_LOGD("UVC_NATIVE", "uvc_close_device end");
  pthread_mutex_unlock(&g_uvc_state.mutex);
}

FFI_PLUGIN_EXPORT int uvc_is_previewing(void) {
  pthread_mutex_lock(&g_uvc_state.mutex);
  int previewing = g_uvc_state.previewing;
  pthread_mutex_unlock(&g_uvc_state.mutex);
  return previewing;
}

FFI_PLUGIN_EXPORT int uvc_frame_width(void) {
  pthread_mutex_lock(&g_uvc_state.mutex);
  int width = g_uvc_state.frame_width;
  pthread_mutex_unlock(&g_uvc_state.mutex);
  return width;
}

FFI_PLUGIN_EXPORT int uvc_frame_height(void) {
  pthread_mutex_lock(&g_uvc_state.mutex);
  int height = g_uvc_state.frame_height;
  pthread_mutex_unlock(&g_uvc_state.mutex);
  return height;
}

FFI_PLUGIN_EXPORT int uvc_copy_latest_frame_rgba(uint8_t *buffer, int buffer_length) {
  return uvc_copy_latest_frame_rgba_with_metadata(buffer, buffer_length, NULL, NULL, NULL);
}

FFI_PLUGIN_EXPORT int uvc_copy_latest_frame_rgba_with_metadata(
    uint8_t *buffer,
    int buffer_length,
    int *out_width,
    int *out_height,
    int64_t *out_sequence) {
  if (buffer == NULL || buffer_length <= 0) {
    return 0;
  }

  pthread_mutex_lock(&g_uvc_state.mutex);
  if (g_uvc_state.latest_rgba == NULL || g_uvc_state.latest_rgba_bytes == 0) {
    pthread_mutex_unlock(&g_uvc_state.mutex);
    return 0;
  }

  const int bytes_to_copy = g_uvc_state.latest_rgba_bytes < (size_t)buffer_length
      ? (int)g_uvc_state.latest_rgba_bytes
      : buffer_length;
  memcpy(buffer, g_uvc_state.latest_rgba, bytes_to_copy);
  if (out_width != NULL) {
    *out_width = g_uvc_state.frame_width;
  }
  if (out_height != NULL) {
    *out_height = g_uvc_state.frame_height;
  }
  if (out_sequence != NULL) {
    *out_sequence = g_uvc_state.latest_sequence;
  }
  pthread_mutex_unlock(&g_uvc_state.mutex);
  return bytes_to_copy;
}

FFI_PLUGIN_EXPORT void uvc_set_frame_listener(uvc_frame_listener_t listener) {
  pthread_mutex_lock(&g_uvc_state.mutex);
  g_uvc_state.frame_listener = listener;
  pthread_mutex_unlock(&g_uvc_state.mutex);
}

FFI_PLUGIN_EXPORT const char *uvc_last_error(void) {
  return g_uvc_state.last_error;
}

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

FFI_PLUGIN_EXPORT int uvc_ctrl_get_all_json(uint8_t *buffer, int buffer_length) {
  if (buffer == NULL || buffer_length <= 0) {
    return 0;
  }

  pthread_mutex_lock(&g_uvc_state.mutex);
  uvc_device_handle_t *devh = g_uvc_state.devh;
  pthread_mutex_unlock(&g_uvc_state.mutex);

  if (devh == NULL) {
    return 0;
  }

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

FFI_PLUGIN_EXPORT int uvc_ctrl_get_bm_controls_json(uint8_t *buffer, int buffer_length) {
  if (buffer == NULL || buffer_length <= 0) {
    return 0;
  }

  pthread_mutex_lock(&g_uvc_state.mutex);
  uvc_device_handle_t *devh = g_uvc_state.devh;
  pthread_mutex_unlock(&g_uvc_state.mutex);

  if (devh == NULL) {
    return 0;
  }

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

FFI_PLUGIN_EXPORT int32_t uvc_ctrl_get(int ctrl_id) {
  pthread_mutex_lock(&g_uvc_state.mutex);
  uvc_device_handle_t *devh = g_uvc_state.devh;
  pthread_mutex_unlock(&g_uvc_state.mutex);

  if (devh == NULL) {
    return INT32_MIN;
  }

  int32_t value = 0;
  int ok = ctrl_get_raw(devh, ctrl_id, UVC_GET_CUR, &value);
  return ok ? value : INT32_MIN;
}

FFI_PLUGIN_EXPORT int uvc_ctrl_set(int ctrl_id, int32_t value) {
  pthread_mutex_lock(&g_uvc_state.mutex);
  uvc_device_handle_t *devh = g_uvc_state.devh;
  pthread_mutex_unlock(&g_uvc_state.mutex);

  if (devh == NULL) {
    set_last_error("Camera is not open");
    return UVC_ERROR_NO_DEVICE;
  }

  int result = ctrl_set_raw(devh, ctrl_id, value);
  if (result != UVC_SUCCESS) {
    set_last_error("uvc_ctrl_set failed ctrl_id=%d value=%d err=%d", ctrl_id, value, result);
    UVC_LOGW("UVC_NATIVE", "uvc_ctrl_set failed ctrl_id=%d value=%d err=%d", ctrl_id, value, result);
  }
  return result;
}

static int with_open_device(uvc_device_handle_t **out_devh) {
  pthread_mutex_lock(&g_uvc_state.mutex);
  uvc_device_handle_t *devh = g_uvc_state.devh;
  pthread_mutex_unlock(&g_uvc_state.mutex);

  if (devh == NULL) {
    set_last_error("Camera is not open");
    return 0;
  }

  *out_devh = devh;
  return 1;
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

FFI_PLUGIN_EXPORT int uvc_get_white_balance_component_json(uint8_t *buffer, int buffer_length) {
  uvc_device_handle_t *devh = NULL;
  uint16_t blue = 0;
  uint16_t red = 0;
  if (!with_open_device(&devh)) return 0;
  if (uvc_get_white_balance_component(devh, &blue, &red, UVC_GET_CUR) != UVC_SUCCESS) return 0;
  return write_json_payload(buffer, buffer_length, "{\"blue\":%u,\"red\":%u}", blue, red);
}

FFI_PLUGIN_EXPORT int uvc_set_white_balance_component_values(uint16_t blue, uint16_t red) {
  uvc_device_handle_t *devh = NULL;
  if (!with_open_device(&devh)) return UVC_ERROR_NO_DEVICE;
  return (int)uvc_set_white_balance_component(devh, blue, red);
}

FFI_PLUGIN_EXPORT int uvc_get_focus_rel_json(uint8_t *buffer, int buffer_length) {
  uvc_device_handle_t *devh = NULL;
  int8_t focus_rel = 0;
  uint8_t speed = 0;
  if (!with_open_device(&devh)) return 0;
  if (uvc_get_focus_rel(devh, &focus_rel, &speed, UVC_GET_CUR) != UVC_SUCCESS) return 0;
  return write_json_payload(
      buffer,
      buffer_length,
      "{\"focusRel\":%d,\"speed\":%u}",
      (int)focus_rel,
      speed);
}

FFI_PLUGIN_EXPORT int uvc_set_focus_rel_values(int8_t focus_rel, uint8_t speed) {
  uvc_device_handle_t *devh = NULL;
  if (!with_open_device(&devh)) return UVC_ERROR_NO_DEVICE;
  return (int)uvc_set_focus_rel(devh, focus_rel, speed);
}

FFI_PLUGIN_EXPORT int uvc_get_zoom_rel_json(uint8_t *buffer, int buffer_length) {
  uvc_device_handle_t *devh = NULL;
  int8_t zoom_rel = 0;
  uint8_t digital_zoom = 0;
  uint8_t speed = 0;
  if (!with_open_device(&devh)) return 0;
  if (uvc_get_zoom_rel(devh, &zoom_rel, &digital_zoom, &speed, UVC_GET_CUR) != UVC_SUCCESS) return 0;
  return write_json_payload(
      buffer,
      buffer_length,
      "{\"zoomRel\":%d,\"digitalZoom\":%u,\"speed\":%u}",
      (int)zoom_rel,
      digital_zoom,
      speed);
}

FFI_PLUGIN_EXPORT int uvc_set_zoom_rel_values(int8_t zoom_rel, uint8_t digital_zoom, uint8_t speed) {
  uvc_device_handle_t *devh = NULL;
  if (!with_open_device(&devh)) return UVC_ERROR_NO_DEVICE;
  return (int)uvc_set_zoom_rel(devh, zoom_rel, digital_zoom, speed);
}

FFI_PLUGIN_EXPORT int uvc_get_pantilt_abs_json(uint8_t *buffer, int buffer_length) {
  uvc_device_handle_t *devh = NULL;
  int32_t pan = 0;
  int32_t tilt = 0;
  if (!with_open_device(&devh)) return 0;
  if (uvc_get_pantilt_abs(devh, &pan, &tilt, UVC_GET_CUR) != UVC_SUCCESS) return 0;
  return write_json_payload(buffer, buffer_length, "{\"pan\":%d,\"tilt\":%d}", pan, tilt);
}

FFI_PLUGIN_EXPORT int uvc_set_pantilt_abs_values(int32_t pan, int32_t tilt) {
  uvc_device_handle_t *devh = NULL;
  if (!with_open_device(&devh)) return UVC_ERROR_NO_DEVICE;
  return (int)uvc_set_pantilt_abs(devh, pan, tilt);
}

FFI_PLUGIN_EXPORT int uvc_get_pantilt_rel_json(uint8_t *buffer, int buffer_length) {
  uvc_device_handle_t *devh = NULL;
  int8_t pan_rel = 0;
  uint8_t pan_speed = 0;
  int8_t tilt_rel = 0;
  uint8_t tilt_speed = 0;
  if (!with_open_device(&devh)) return 0;
  if (uvc_get_pantilt_rel(devh, &pan_rel, &pan_speed, &tilt_rel, &tilt_speed, UVC_GET_CUR) != UVC_SUCCESS) return 0;
  return write_json_payload(
      buffer,
      buffer_length,
      "{\"panRel\":%d,\"panSpeed\":%u,\"tiltRel\":%d,\"tiltSpeed\":%u}",
      (int)pan_rel,
      pan_speed,
      (int)tilt_rel,
      tilt_speed);
}

FFI_PLUGIN_EXPORT int uvc_set_pantilt_rel_values(int8_t pan_rel, uint8_t pan_speed, int8_t tilt_rel, uint8_t tilt_speed) {
  uvc_device_handle_t *devh = NULL;
  if (!with_open_device(&devh)) return UVC_ERROR_NO_DEVICE;
  return (int)uvc_set_pantilt_rel(devh, pan_rel, pan_speed, tilt_rel, tilt_speed);
}

FFI_PLUGIN_EXPORT int uvc_get_roll_rel_json(uint8_t *buffer, int buffer_length) {
  uvc_device_handle_t *devh = NULL;
  int8_t roll_rel = 0;
  uint8_t speed = 0;
  if (!with_open_device(&devh)) return 0;
  if (uvc_get_roll_rel(devh, &roll_rel, &speed, UVC_GET_CUR) != UVC_SUCCESS) return 0;
  return write_json_payload(
      buffer,
      buffer_length,
      "{\"rollRel\":%d,\"speed\":%u}",
      (int)roll_rel,
      speed);
}

FFI_PLUGIN_EXPORT int uvc_set_roll_rel_values(int8_t roll_rel, uint8_t speed) {
  uvc_device_handle_t *devh = NULL;
  if (!with_open_device(&devh)) return UVC_ERROR_NO_DEVICE;
  return (int)uvc_set_roll_rel(devh, roll_rel, speed);
}

FFI_PLUGIN_EXPORT int uvc_get_digital_window_json(uint8_t *buffer, int buffer_length) {
  uvc_device_handle_t *devh = NULL;
  uint16_t top = 0;
  uint16_t left = 0;
  uint16_t bottom = 0;
  uint16_t right = 0;
  uint16_t num_steps = 0;
  uint16_t num_steps_units = 0;
  if (!with_open_device(&devh)) return 0;
  if (uvc_get_digital_window(
          devh,
          &top,
          &left,
          &bottom,
          &right,
          &num_steps,
          &num_steps_units,
          UVC_GET_CUR) != UVC_SUCCESS) {
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
    uint16_t window_top,
    uint16_t window_left,
    uint16_t window_bottom,
    uint16_t window_right,
    uint16_t num_steps,
    uint16_t num_steps_units) {
  uvc_device_handle_t *devh = NULL;
  if (!with_open_device(&devh)) return UVC_ERROR_NO_DEVICE;
  return (int)uvc_set_digital_window(
      devh,
      window_top,
      window_left,
      window_bottom,
      window_right,
      num_steps,
      num_steps_units);
}

FFI_PLUGIN_EXPORT int uvc_get_region_of_interest_json(uint8_t *buffer, int buffer_length) {
  uvc_device_handle_t *devh = NULL;
  uint16_t top = 0;
  uint16_t left = 0;
  uint16_t bottom = 0;
  uint16_t right = 0;
  uint16_t auto_controls = 0;
  if (!with_open_device(&devh)) return 0;
  if (uvc_get_digital_roi(
          devh,
          &top,
          &left,
          &bottom,
          &right,
          &auto_controls,
          UVC_GET_CUR) != UVC_SUCCESS) {
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
    uint16_t roi_top,
    uint16_t roi_left,
    uint16_t roi_bottom,
    uint16_t roi_right,
    uint16_t auto_controls) {
  uvc_device_handle_t *devh = NULL;
  if (!with_open_device(&devh)) return UVC_ERROR_NO_DEVICE;
  return (int)uvc_set_digital_roi(
      devh,
      roi_top,
      roi_left,
      roi_bottom,
      roi_right,
      auto_controls);
}
