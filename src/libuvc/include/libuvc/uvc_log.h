#ifndef LIBUVC_UVC_LOG_H
#define LIBUVC_UVC_LOG_H

#include <stdarg.h>
#include <stdio.h>

#if defined(__ANDROID__)
#include <android/log.h>
#endif

#ifdef __cplusplus
extern "C" {
#endif

enum uvc_native_log_level {
  UVC_LOG_LEVEL_ERROR = 0,
  UVC_LOG_LEVEL_WARN = 1,
  UVC_LOG_LEVEL_INFO = 2,
  UVC_LOG_LEVEL_DEBUG = 3,
  UVC_LOG_LEVEL_TRACE = 4,
};

#ifndef UVC_LOG_LEVEL_DEFAULT
#define UVC_LOG_LEVEL_DEFAULT UVC_LOG_LEVEL_INFO
#endif

extern int g_uvc_native_log_level;

static inline int uvc_log_enabled(int level) {
  return level <= g_uvc_native_log_level;
}

static inline const char *uvc_log_level_name(int level) {
  switch (level) {
    case UVC_LOG_LEVEL_ERROR:
      return "E";
    case UVC_LOG_LEVEL_WARN:
      return "W";
    case UVC_LOG_LEVEL_INFO:
      return "I";
    case UVC_LOG_LEVEL_DEBUG:
      return "D";
    case UVC_LOG_LEVEL_TRACE:
      return "T";
    default:
      return "?";
  }
}

static inline void uvc_log_write(int level, const char *tag, const char *scope, const char *format, ...) {
  if (!uvc_log_enabled(level)) {
    return;
  }

  char message[768];
  va_list args;
  va_start(args, format);
  vsnprintf(message, sizeof(message), format, args);
  va_end(args);

#if defined(__ANDROID__)
  int android_priority = ANDROID_LOG_INFO;
  switch (level) {
    case UVC_LOG_LEVEL_ERROR:
      android_priority = ANDROID_LOG_ERROR;
      break;
    case UVC_LOG_LEVEL_WARN:
      android_priority = ANDROID_LOG_WARN;
      break;
    case UVC_LOG_LEVEL_INFO:
      android_priority = ANDROID_LOG_INFO;
      break;
    default:
      android_priority = ANDROID_LOG_DEBUG;
      break;
  }
  __android_log_print(android_priority, tag, "@@@@%s/%s %s", scope, uvc_log_level_name(level), message);
#else
  fprintf(stderr, "@@@@%s/%s %s\n", scope, uvc_log_level_name(level), message);
#endif
}

#define UVC_LOGE(scope, ...) uvc_log_write(UVC_LOG_LEVEL_ERROR, "flutter_ffi_uvc", scope, __VA_ARGS__)
#define UVC_LOGW(scope, ...) uvc_log_write(UVC_LOG_LEVEL_WARN, "flutter_ffi_uvc", scope, __VA_ARGS__)
#define UVC_LOGI(scope, ...) uvc_log_write(UVC_LOG_LEVEL_INFO, "flutter_ffi_uvc", scope, __VA_ARGS__)
#define UVC_LOGD(scope, ...) uvc_log_write(UVC_LOG_LEVEL_DEBUG, "flutter_ffi_uvc", scope, __VA_ARGS__)
#define UVC_LOGT(scope, ...) uvc_log_write(UVC_LOG_LEVEL_TRACE, "flutter_ffi_uvc", scope, __VA_ARGS__)

#ifdef __cplusplus
}
#endif

#endif
