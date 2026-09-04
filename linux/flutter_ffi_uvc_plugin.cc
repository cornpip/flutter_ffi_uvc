#include "include/flutter_ffi_uvc/flutter_ffi_uvc_plugin.h"

#include <fcntl.h>
#include <limits.h>
#include <linux/netlink.h>
#include <poll.h>
#include <sys/socket.h>
#include <unistd.h>

#include <cerrno>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>

// The plugin reuses the exported FFI entry points implemented by
// ../src/backend_libuvc/flutter_ffi_uvc.c (compiled into this library) for
// texture rendering, mirroring the Windows plugin DLL layout.
#include "flutter_ffi_uvc.h"

namespace {

constexpr char kSysUsbDevices[] = "/sys/bus/usb/devices";
constexpr int kUsbVideoClass = 0x0e;

// ---------------------------------------------------------------------------
// sysfs helpers
// ---------------------------------------------------------------------------

// Reads a single-line sysfs attribute into out (newline stripped).
gboolean SysfsReadAttr(const char* syspath, const char* attr, char* out,
                       size_t out_size) {
  char path[PATH_MAX];
  snprintf(path, sizeof(path), "%s/%s", syspath, attr);
  FILE* file = fopen(path, "r");
  if (file == nullptr) return FALSE;
  const gboolean ok = fgets(out, static_cast<int>(out_size), file) != nullptr;
  fclose(file);
  if (!ok) {
    out[0] = '\0';
    return FALSE;
  }
  out[strcspn(out, "\n")] = '\0';
  return TRUE;
}

long SysfsReadLong(const char* syspath, const char* attr, int base,
                   long fallback) {
  char text[64];
  if (!SysfsReadAttr(syspath, attr, text, sizeof(text))) return fallback;
  char* end = nullptr;
  const long value = strtol(text, &end, base);
  return end == text ? fallback : value;
}

// True when the device itself or any of its interfaces is USB video class.
gboolean DeviceIsVideo(const char* syspath, const char* name) {
  if (SysfsReadLong(syspath, "bDeviceClass", 16, -1) == kUsbVideoClass) {
    return TRUE;
  }
  g_autoptr(GDir) dir = g_dir_open(syspath, 0, nullptr);
  if (dir == nullptr) return FALSE;
  const size_t name_length = strlen(name);
  const gchar* entry;
  while ((entry = g_dir_read_name(dir)) != nullptr) {
    // Interface directories are named "<device>:<config>.<interface>".
    if (strncmp(entry, name, name_length) != 0 || entry[name_length] != ':') {
      continue;
    }
    char interface_path[PATH_MAX];
    snprintf(interface_path, sizeof(interface_path), "%s/%s", syspath, entry);
    if (SysfsReadLong(interface_path, "bInterfaceClass", 16, -1) ==
        kUsbVideoClass) {
      return TRUE;
    }
  }
  return FALSE;
}

int DeviceIdFor(int busnum, int devnum) { return busnum * 1000 + devnum; }

void DevnodeFor(int busnum, int devnum, char* out, size_t out_size) {
  snprintf(out, out_size, "/dev/bus/usb/%03d/%03d", busnum, devnum);
}

// Matches the map shape produced by the Android and Windows plugins.
FlValue* DeviceMapNew(int busnum, int devnum, int vendor_id, int product_id,
                      const char* product, const char* manufacturer,
                      const char* serial) {
  char devnode[64];
  DevnodeFor(busnum, devnum, devnode, sizeof(devnode));
  FlValue* map = fl_value_new_map();
  fl_value_set_string_take(map, "deviceId",
                           fl_value_new_int(DeviceIdFor(busnum, devnum)));
  fl_value_set_string_take(map, "deviceName", fl_value_new_string(devnode));
  fl_value_set_string_take(map, "vendorId", fl_value_new_int(vendor_id));
  fl_value_set_string_take(map, "productId", fl_value_new_int(product_id));
  fl_value_set_string_take(map, "productName",
                           fl_value_new_string(product != nullptr ? product : ""));
  fl_value_set_string_take(
      map, "manufacturerName",
      fl_value_new_string(manufacturer != nullptr ? manufacturer : ""));
  fl_value_set_string_take(map, "serialNumber",
                           fl_value_new_string(serial != nullptr ? serial : ""));
  fl_value_set_string_take(
      map, "hasPermission",
      fl_value_new_bool(access(devnode, R_OK | W_OK) == 0));
  return map;
}

FlValue* DeviceMapFromSysfs(const char* syspath) {
  const int busnum = static_cast<int>(SysfsReadLong(syspath, "busnum", 10, -1));
  const int devnum = static_cast<int>(SysfsReadLong(syspath, "devnum", 10, -1));
  if (busnum < 0 || devnum < 0) return nullptr;
  const int vendor_id =
      static_cast<int>(SysfsReadLong(syspath, "idVendor", 16, 0));
  const int product_id =
      static_cast<int>(SysfsReadLong(syspath, "idProduct", 16, 0));
  char product[256] = "";
  char manufacturer[256] = "";
  char serial[256] = "";
  SysfsReadAttr(syspath, "product", product, sizeof(product));
  SysfsReadAttr(syspath, "manufacturer", manufacturer, sizeof(manufacturer));
  SysfsReadAttr(syspath, "serial", serial, sizeof(serial));
  return DeviceMapNew(busnum, devnum, vendor_id, product_id, product,
                      manufacturer, serial);
}

int64_t Int64FromArgs(FlValue* args, const char* key) {
  if (args == nullptr || fl_value_get_type(args) != FL_VALUE_TYPE_MAP) {
    return -1;
  }
  FlValue* value = fl_value_lookup_string(args, key);
  if (value == nullptr || fl_value_get_type(value) != FL_VALUE_TYPE_INT) {
    return -1;
  }
  return fl_value_get_int(value);
}

// ---------------------------------------------------------------------------
// Preview texture
// ---------------------------------------------------------------------------

struct _FfiUvcTexture {
  FlPixelBufferTexture parent_instance;
  // Owned pixel storage; must stay valid until the next render-thread copy.
  uint8_t* buffer;
  size_t buffer_capacity;
  uint32_t buffer_width;
  uint32_t buffer_height;
  // Registry id of the session this texture renders, 0 when unbound. Guarded
  // by session_mutex, which the render thread holds across its copy so a
  // detach cannot race it.
  GMutex session_mutex;
  uint64_t session_id;
  // Coalesces frame marks so at most one idle callback is pending.
  gint mark_pending;
  // Bare pointer. The plugin outlives every registered texture.
  FlutterFfiUvcPlugin* plugin;
};

G_DECLARE_FINAL_TYPE(FfiUvcTexture, ffi_uvc_texture, FFI_UVC, TEXTURE,
                     FlPixelBufferTexture)
G_DEFINE_TYPE(FfiUvcTexture, ffi_uvc_texture, fl_pixel_buffer_texture_get_type())

// Called on the render thread. Pulls the latest RGBA frame with the current
// preview transform applied, matching the Windows PixelBufferTexture path.
gboolean ffi_uvc_texture_copy_pixels(FlPixelBufferTexture* texture,
                                     const uint8_t** out_buffer,
                                     uint32_t* width, uint32_t* height,
                                     GError** error) {
  FfiUvcTexture* self = FFI_UVC_TEXTURE(texture);

  g_mutex_lock(&self->session_mutex);
  // Pin the session so a destroy from Dart waits for this copy.
  uvc_session_t* session = uvc_session_acquire_id(self->session_id);
  const gboolean pinned = session != nullptr;
  const int frame_w = pinned ? uvc_frame_width(session) : 0;
  const int frame_h = pinned ? uvc_frame_height(session) : 0;
  if (frame_w > 0 && frame_h > 0) {
    int rotation = 0;
    int flip_h = 0;
    int flip_v = 0;
    uvc_get_preview_transform(session, &rotation, &flip_h, &flip_v);
    const gboolean swap = rotation == 90 || rotation == 270;
    const uint32_t out_w = static_cast<uint32_t>(swap ? frame_h : frame_w);
    const uint32_t out_h = static_cast<uint32_t>(swap ? frame_w : frame_h);
    const size_t needed = static_cast<size_t>(out_w) * out_h * 4;
    if (needed > self->buffer_capacity) {
      uint8_t* grown = static_cast<uint8_t*>(realloc(self->buffer, needed));
      if (grown != nullptr) {
        self->buffer = grown;
        self->buffer_capacity = needed;
      }
    }
    if (self->buffer != nullptr && self->buffer_capacity >= needed) {
      int copied_w = 0;
      int copied_h = 0;
      int64_t sequence = 0;
      const int copied = uvc_copy_latest_frame_rgba_transformed(
          session, self->buffer, static_cast<int>(needed), rotation, flip_h,
          flip_v, &copied_w, &copied_h, &sequence);
      if (copied > 0) {
        self->buffer_width = static_cast<uint32_t>(copied_w);
        self->buffer_height = static_cast<uint32_t>(copied_h);
      }
    }
  }
  if (pinned) uvc_session_release(session);
  g_mutex_unlock(&self->session_mutex);

  // When no new frame could be copied, fall back to the previous one so the
  // texture never flashes empty mid-session.
  if (self->buffer == nullptr || self->buffer_width == 0 ||
      self->buffer_height == 0) {
    g_set_error(error, g_quark_from_static_string("flutter_ffi_uvc"), 1,
                "No preview frame available");
    return FALSE;
  }
  *out_buffer = self->buffer;
  *width = self->buffer_width;
  *height = self->buffer_height;
  return TRUE;
}

void ffi_uvc_texture_finalize(GObject* object) {
  FfiUvcTexture* self = FFI_UVC_TEXTURE(object);
  g_mutex_clear(&self->session_mutex);
  free(self->buffer);
  self->buffer = nullptr;
  G_OBJECT_CLASS(ffi_uvc_texture_parent_class)->finalize(object);
}

void ffi_uvc_texture_class_init(FfiUvcTextureClass* klass) {
  FL_PIXEL_BUFFER_TEXTURE_CLASS(klass)->copy_pixels =
      ffi_uvc_texture_copy_pixels;
  G_OBJECT_CLASS(klass)->finalize = ffi_uvc_texture_finalize;
}

void ffi_uvc_texture_init(FfiUvcTexture* self) {
  self->buffer = nullptr;
  self->buffer_capacity = 0;
  self->buffer_width = 0;
  self->buffer_height = 0;
  g_mutex_init(&self->session_mutex);
  self->session_id = 0;
  self->mark_pending = 0;
  self->plugin = nullptr;
}

}  // namespace

// ---------------------------------------------------------------------------
// Plugin
// ---------------------------------------------------------------------------

struct KnownVideoDevice {
  int device_id;
  int vendor_id;
  int product_id;
};

struct _FlutterFfiUvcPlugin {
  GObject parent_instance;

  FlTextureRegistrar* texture_registrar;
  // Owned ref; the stream handlers hold a bare plugin pointer to avoid a
  // plugin <-> channel reference cycle (the plugin is kept alive by the
  // method-channel handler refs until engine shutdown).
  FlEventChannel* device_event_channel;
  gboolean device_events_listening;

  // texture id -> FfiUvcTexture* (owns a ref).
  GHashTable* textures;

  // int64 session handle -> fd handed to uvc_open_fd, owned until
  // closeUsbDevice. Stored as fd + 1 so descriptor 0 is not a null value.
  GHashTable* session_fds;

  // Video devices seen via enumeration or attach events, keyed by the sysfs
  // device basename (e.g. "1-2"), so detach events can be classified after
  // the device disappeared from sysfs.
  GHashTable* known_video_devices;

  // uevent monitor (device attach/detach events).
  GThread* uevent_thread;
  int uevent_fd;
  int uevent_wakeup_pipe[2];
};

G_DEFINE_TYPE(FlutterFfiUvcPlugin, flutter_ffi_uvc_plugin, g_object_get_type())

namespace {

// Runs on the main thread with the ref taken in OnNativeFrame.
gboolean MarkFrameIdle(gpointer user_data) {
  FfiUvcTexture* texture = FFI_UVC_TEXTURE(user_data);
  g_atomic_int_set(&texture->mark_pending, 0);
  if (texture->session_id != 0 && texture->plugin != nullptr) {
    fl_texture_registrar_mark_texture_frame_available(
        texture->plugin->texture_registrar, FL_TEXTURE(texture));
  }
  g_object_unref(texture);
  return G_SOURCE_REMOVE;
}

// Frame listener. Runs on the native delivery thread with the bound texture
// as user_data. The texture outlives this call: clearing the listener in
// UnbindTexture returns only after it has finished.
void OnNativeFrame(void* user_data, int64_t /*sequence*/) {
  FfiUvcTexture* texture = FFI_UVC_TEXTURE(user_data);
  if (g_atomic_int_compare_and_exchange(&texture->mark_pending, 0, 1)) {
    g_idle_add(MarkFrameIdle, g_object_ref(texture));
  }
}

// Unbinds a texture from its session and clears the session's frame
// listener. Waits for an in-flight render-thread copy.
void UnbindTexture(FfiUvcTexture* texture) {
  g_mutex_lock(&texture->session_mutex);
  const uint64_t session_id = texture->session_id;
  texture->session_id = 0;
  g_mutex_unlock(&texture->session_mutex);
  uvc_session_t* session = uvc_session_acquire_id(session_id);
  if (session != nullptr) {
    uvc_set_frame_listener(session, nullptr, nullptr);
    uvc_session_release(session);
  }
}

// Unbinds whichever texture currently renders the session, if any.
void UnbindSession(FlutterFfiUvcPlugin* self, uint64_t session_id) {
  GHashTableIter iter;
  gpointer key = nullptr;
  gpointer value = nullptr;
  g_hash_table_iter_init(&iter, self->textures);
  while (g_hash_table_iter_next(&iter, &key, &value)) {
    FfiUvcTexture* texture = FFI_UVC_TEXTURE(value);
    g_mutex_lock(&texture->session_mutex);
    const gboolean match = texture->session_id == session_id;
    g_mutex_unlock(&texture->session_mutex);
    if (match) UnbindTexture(texture);
  }
}

// The Dart side passes the session's registry id (uvc_session_id). 0 when
// missing.
int64_t SessionIdFromArgs(FlValue* args) {
  const int64_t id = Int64FromArgs(args, "sessionHandle");
  return id > 0 ? id : 0;
}

// Releases fds of sessions that a hot restart leaked and a finalizer has
// since destroyed.
void CloseDeadSessionFds(FlutterFfiUvcPlugin* self) {
  GHashTableIter iter;
  gpointer key = nullptr;
  gpointer value = nullptr;
  g_hash_table_iter_init(&iter, self->session_fds);
  while (g_hash_table_iter_next(&iter, &key, &value)) {
    uvc_session_t* session = uvc_session_acquire_id(
        static_cast<uint64_t>(*static_cast<int64_t*>(key)));
    if (session != nullptr) {
      uvc_session_release(session);
      continue;
    }
    close(GPOINTER_TO_INT(value) - 1);
    g_hash_table_iter_remove(&iter);
  }
}

void CloseSessionFd(FlutterFfiUvcPlugin* self, int64_t session_id) {
  const int64_t key = session_id;
  gpointer value = g_hash_table_lookup(self->session_fds, &key);
  if (value == nullptr) return;
  close(GPOINTER_TO_INT(value) - 1);
  g_hash_table_remove(self->session_fds, &key);
}

int64_t* Int64KeyNew(int64_t value) {
  int64_t* key = g_new(int64_t, 1);
  *key = value;
  return key;
}

guint Int64Hash(gconstpointer key) {
  return g_int64_hash(key);
}

gboolean Int64Equal(gconstpointer a, gconstpointer b) {
  return g_int64_equal(a, b);
}

// ---------------------------------------------------------------------------
// USB channel
// ---------------------------------------------------------------------------

void RememberVideoDevice(FlutterFfiUvcPlugin* self, const char* name,
                         FlValue* device_map) {
  KnownVideoDevice* info = g_new0(KnownVideoDevice, 1);
  info->device_id = static_cast<int>(
      fl_value_get_int(fl_value_lookup_string(device_map, "deviceId")));
  info->vendor_id = static_cast<int>(
      fl_value_get_int(fl_value_lookup_string(device_map, "vendorId")));
  info->product_id = static_cast<int>(
      fl_value_get_int(fl_value_lookup_string(device_map, "productId")));
  g_hash_table_replace(self->known_video_devices, g_strdup(name), info);
}

// Records every currently attached video device without emitting events, so
// detach events work for devices that were attached before the listener
// subscribed and were never enumerated through listUsbDevices.
void SeedKnownVideoDevices(FlutterFfiUvcPlugin* self) {
  g_autoptr(GDir) dir = g_dir_open(kSysUsbDevices, 0, nullptr);
  if (dir == nullptr) return;
  const gchar* name;
  while ((name = g_dir_read_name(dir)) != nullptr) {
    if (!g_ascii_isdigit(name[0]) || strchr(name, ':') != nullptr) continue;
    char syspath[PATH_MAX];
    snprintf(syspath, sizeof(syspath), "%s/%s", kSysUsbDevices, name);
    if (!DeviceIsVideo(syspath, name)) continue;
    FlValue* device_map = DeviceMapFromSysfs(syspath);
    if (device_map != nullptr) {
      RememberVideoDevice(self, name, device_map);
      fl_value_unref(device_map);
    }
  }
}

FlValue* ListVideoDevices(FlutterFfiUvcPlugin* self) {
  FlValue* list = fl_value_new_list();
  g_autoptr(GDir) dir = g_dir_open(kSysUsbDevices, 0, nullptr);
  if (dir == nullptr) return list;
  const gchar* name;
  while ((name = g_dir_read_name(dir)) != nullptr) {
    // Device directories look like "1-2" or "1-2.4"; interface directories
    // contain ':' and root hubs start with "usb".
    if (!g_ascii_isdigit(name[0]) || strchr(name, ':') != nullptr) continue;
    char syspath[PATH_MAX];
    snprintf(syspath, sizeof(syspath), "%s/%s", kSysUsbDevices, name);
    if (!DeviceIsVideo(syspath, name)) continue;
    FlValue* device_map = DeviceMapFromSysfs(syspath);
    if (device_map == nullptr) continue;
    RememberVideoDevice(self, name, device_map);
    fl_value_append_take(list, device_map);
  }
  return list;
}

// Finds the /dev/bus/usb node for a deviceId assigned by ListVideoDevices.
gboolean DevnodeForDeviceId(int64_t device_id, char* out, size_t out_size) {
  const int busnum = static_cast<int>(device_id / 1000);
  const int devnum = static_cast<int>(device_id % 1000);
  if (busnum <= 0 || devnum <= 0) return FALSE;
  DevnodeFor(busnum, devnum, out, out_size);
  return access(out, F_OK) == 0;
}

void HandleUsbCall(FlutterFfiUvcPlugin* self, FlMethodCall* method_call) {
  const gchar* method = fl_method_call_get_name(method_call);
  FlValue* args = fl_method_call_get_args(method_call);
  g_autoptr(FlMethodResponse) response = nullptr;

  if (strcmp(method, "ensureCameraPermission") == 0) {
    // Linux desktops have no runtime camera permission dialog; device node
    // access problems surface as open failures instead.
    g_autoptr(FlValue) result = fl_value_new_bool(TRUE);
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(result));
  } else if (strcmp(method, "listUsbDevices") == 0) {
    g_autoptr(FlValue) result = ListVideoDevices(self);
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(result));
  } else if (strcmp(method, "openUsbDevice") == 0) {
    const int64_t session_id = SessionIdFromArgs(args);
    const int64_t device_id = Int64FromArgs(args, "deviceId");
    char devnode[64];
    if (session_id == 0) {
      response = FL_METHOD_RESPONSE(fl_method_error_response_new(
          "invalid_args", "sessionHandle is required.", nullptr));
    } else if (device_id < 0 || !DevnodeForDeviceId(device_id, devnode, sizeof(devnode))) {
      g_autofree gchar* message = g_strdup_printf(
          "No UVC device with id %" G_GINT64_FORMAT, device_id);
      response = FL_METHOD_RESPONSE(
          fl_method_error_response_new("device_not_found", message, nullptr));
    } else {
      const int fd = open(devnode, O_RDWR | O_CLOEXEC);
      if (fd < 0) {
        g_autofree gchar* message = g_strdup_printf(
            "Unable to open %s: %s%s", devnode, g_strerror(errno),
            errno == EACCES
                ? " (add a udev rule granting your user read-write access)"
                : "");
        response = FL_METHOD_RESPONSE(
            fl_method_error_response_new("open_failed", message, nullptr));
      } else {
        // A session holds one device. Opening another replaces it.
        CloseSessionFd(self, session_id);
        CloseDeadSessionFds(self);
        g_hash_table_replace(self->session_fds, Int64KeyNew(session_id),
                             GINT_TO_POINTER(fd + 1));
        // The Dart layer passes this value straight to uvc_open_fd, the same
        // flow as Android's UsbDeviceConnection file descriptor.
        g_autoptr(FlValue) result = fl_value_new_map();
        fl_value_set_string_take(result, "fileDescriptor", fl_value_new_int(fd));
        response = FL_METHOD_RESPONSE(fl_method_success_response_new(result));
      }
    }
  } else if (strcmp(method, "closeUsbDevice") == 0) {
    // The Dart layer closes the native device before this call. The close
    // here is for an instance collected without dispose(), so libuvc never
    // runs on a released fd.
    const int64_t session_id = SessionIdFromArgs(args);
    if (session_id != 0) {
      uvc_session_t* session =
          uvc_session_acquire_id(static_cast<uint64_t>(session_id));
      if (session != nullptr) {
        uvc_close_device(session);
        uvc_session_release(session);
      }
      CloseSessionFd(self, session_id);
    }
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  } else {
    response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  }

  fl_method_call_respond(method_call, response, nullptr);
}

// ---------------------------------------------------------------------------
// Texture channel
// ---------------------------------------------------------------------------

void HandleTextureCall(FlutterFfiUvcPlugin* self, FlMethodCall* method_call) {
  const gchar* method = fl_method_call_get_name(method_call);
  FlValue* args = fl_method_call_get_args(method_call);
  g_autoptr(FlMethodResponse) response = nullptr;

  if (strcmp(method, "createPreviewTexture") == 0) {
    FfiUvcTexture* texture = FFI_UVC_TEXTURE(
        g_object_new(ffi_uvc_texture_get_type(), nullptr));
    if (!fl_texture_registrar_register_texture(self->texture_registrar,
                                               FL_TEXTURE(texture))) {
      g_object_unref(texture);
      response = FL_METHOD_RESPONSE(fl_method_error_response_new(
          "texture_create_failed", "RegisterTexture failed", nullptr));
    } else {
      const int64_t texture_id = fl_texture_get_id(FL_TEXTURE(texture));
      texture->plugin = self;
      g_hash_table_replace(self->textures, Int64KeyNew(texture_id), texture);
      g_autoptr(FlValue) result = fl_value_new_int(texture_id);
      response = FL_METHOD_RESPONSE(fl_method_success_response_new(result));
    }
  } else if (strcmp(method, "disposePreviewTexture") == 0) {
    const int64_t texture_id = Int64FromArgs(args, "textureId");
    gpointer texture = g_hash_table_lookup(self->textures, &texture_id);
    if (texture != nullptr) {
      UnbindTexture(FFI_UVC_TEXTURE(texture));
      fl_texture_registrar_unregister_texture(self->texture_registrar,
                                              FL_TEXTURE(texture));
      g_hash_table_remove(self->textures, &texture_id);
    }
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  } else if (strcmp(method, "attachPreviewTexture") == 0) {
    const int64_t session_id = SessionIdFromArgs(args);
    const int64_t texture_id = Int64FromArgs(args, "textureId");
    gpointer texture = g_hash_table_lookup(self->textures, &texture_id);
    uvc_session_t* session = nullptr;
    if (session_id == 0) {
      response = FL_METHOD_RESPONSE(fl_method_error_response_new(
          "invalid_args", "sessionHandle is required.", nullptr));
    } else if (texture == nullptr) {
      response = FL_METHOD_RESPONSE(fl_method_error_response_new(
          "texture_not_found", "Unknown textureId", nullptr));
    } else if ((session = uvc_session_acquire_id(
                    static_cast<uint64_t>(session_id))) == nullptr) {
      response = FL_METHOD_RESPONSE(fl_method_error_response_new(
          "invalid_session", "sessionHandle is not a live session", nullptr));
    } else {
      // One texture per session and one session per texture.
      UnbindSession(self, static_cast<uint64_t>(session_id));
      FfiUvcTexture* bound = FFI_UVC_TEXTURE(texture);
      UnbindTexture(bound);
      g_mutex_lock(&bound->session_mutex);
      bound->session_id = static_cast<uint64_t>(session_id);
      g_mutex_unlock(&bound->session_mutex);
      uvc_set_frame_listener(session, OnNativeFrame, bound);
      uvc_session_release(session);
      response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
    }
  } else if (strcmp(method, "detachPreviewSession") == 0) {
    // Dart calls this before destroying the session.
    const int64_t session_id = SessionIdFromArgs(args);
    if (session_id != 0) UnbindSession(self, static_cast<uint64_t>(session_id));
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  } else {
    response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  }

  fl_method_call_respond(method_call, response, nullptr);
}

// ---------------------------------------------------------------------------
// Device attach/detach events (netlink uevent monitor)
// ---------------------------------------------------------------------------

struct UeventMessage {
  FlutterFfiUvcPlugin* plugin;  // owns a ref
  gboolean attached;
  // TRUE when the event came from a video-class usb_interface rather than
  // the usb_device itself.
  gboolean video_interface;
  // Attach: sysfs basename of the parent usb_device of a video interface.
  // Detach: basename of the removed device or interface parent.
  char device_name[128];
  // usb_device removals only, parsed from the uevent environment.
  int vendor_id;
  int product_id;
  int busnum;
  int devnum;
};

void EmitDeviceEvent(FlutterFfiUvcPlugin* self, gboolean attached,
                     FlValue* device_map) {
  if (!self->device_events_listening || self->device_event_channel == nullptr) {
    fl_value_unref(device_map);
    return;
  }
  g_autoptr(FlValue) event = fl_value_new_map();
  fl_value_set_string_take(event, "event",
                           fl_value_new_string(attached ? "attached" : "detached"));
  fl_value_set_string_take(event, "device", device_map);
  fl_event_channel_send(self->device_event_channel, event, nullptr, nullptr);
}

gboolean UeventIdle(gpointer user_data) {
  UeventMessage* message = static_cast<UeventMessage*>(user_data);
  FlutterFfiUvcPlugin* self = message->plugin;

  // The message's plugin ref keeps the object alive, but an idle scheduled
  // right before engine shutdown can still run after dispose cleared the
  // plugin's state.
  if (self->known_video_devices == nullptr) {
    g_object_unref(self);
    g_free(message);
    return G_SOURCE_REMOVE;
  }

  if (message->attached) {
    char syspath[PATH_MAX];
    snprintf(syspath, sizeof(syspath), "%s/%s", kSysUsbDevices,
             message->device_name);
    FlValue* device_map = DeviceMapFromSysfs(syspath);
    if (device_map != nullptr) {
      // Cameras expose several video interfaces and each one produces an add
      // event, so a matching remembered entry means a duplicate. Compare by
      // deviceId rather than presence alone: a device unplugged while the
      // monitor was stopped leaves a stale entry under the same sysfs name,
      // and its replug arrives with a fresh devnum.
      KnownVideoDevice* known = static_cast<KnownVideoDevice*>(
          g_hash_table_lookup(self->known_video_devices, message->device_name));
      const int device_id = static_cast<int>(
          fl_value_get_int(fl_value_lookup_string(device_map, "deviceId")));
      if (known != nullptr && known->device_id == device_id) {
        fl_value_unref(device_map);
      } else {
        RememberVideoDevice(self, message->device_name, device_map);
        EmitDeviceEvent(self, TRUE, device_map);
      }
    }
  } else {
    KnownVideoDevice* info = static_cast<KnownVideoDevice*>(g_hash_table_lookup(
        self->known_video_devices, message->device_name));
    if (info == nullptr) {
      // A video-interface removal proves the vanished device was a camera
      // even when nothing cached it (unplugged during the seed scan, before
      // it reached this entry). Record a placeholder; the usb_device removal
      // that ends the removal burst carries the identity and emits below.
      if (message->video_interface) {
        g_hash_table_replace(self->known_video_devices,
                             g_strdup(message->device_name),
                             g_new0(KnownVideoDevice, 1));
      }
    } else if (!message->video_interface) {
      // Emit on the usb_device removal only: cameras expose several video
      // interfaces, so emitting per interface removal would double-report
      // one unplug. The device is gone from sysfs; rebuild the event from
      // the cached identity plus the uevent environment.
      const int device_id = info->device_id;
      const int busnum =
          message->busnum > 0 ? message->busnum : device_id / 1000;
      const int devnum =
          message->devnum > 0 ? message->devnum : device_id % 1000;
      const int vendor_id =
          message->vendor_id > 0 ? message->vendor_id : info->vendor_id;
      const int product_id =
          message->product_id > 0 ? message->product_id : info->product_id;
      g_hash_table_remove(self->known_video_devices, message->device_name);
      if (busnum > 0 && devnum > 0) {
        FlValue* device_map = DeviceMapNew(busnum, devnum, vendor_id,
                                           product_id, "", "", "");
        EmitDeviceEvent(self, FALSE, device_map);
      }
    }
    // A video-interface removal with a cached entry keeps the entry: the
    // usb_device removal emits, and a device reset (interfaces recreated,
    // devnum unchanged) passes without a spurious detach/attach pair.
  }

  g_object_unref(self);
  g_free(message);
  return G_SOURCE_REMOVE;
}

// Parses one uevent datagram on the monitor thread and forwards relevant
// events to the main thread.
void ProcessUevent(FlutterFfiUvcPlugin* self, char* buffer, ssize_t length) {
  const char* action = nullptr;
  const char* devpath = nullptr;
  const char* devtype = nullptr;
  const char* interface_triplet = nullptr;
  const char* product = nullptr;
  long busnum = 0;
  long devnum = 0;

  // Datagram layout: "action@devpath\0KEY=VALUE\0KEY=VALUE\0...".
  ssize_t offset = static_cast<ssize_t>(strlen(buffer)) + 1;
  while (offset < length) {
    char* entry = buffer + offset;
    offset += static_cast<ssize_t>(strlen(entry)) + 1;
    if (strncmp(entry, "ACTION=", 7) == 0) action = entry + 7;
    else if (strncmp(entry, "DEVPATH=", 8) == 0) devpath = entry + 8;
    else if (strncmp(entry, "DEVTYPE=", 8) == 0) devtype = entry + 8;
    else if (strncmp(entry, "INTERFACE=", 10) == 0) interface_triplet = entry + 10;
    else if (strncmp(entry, "PRODUCT=", 8) == 0) product = entry + 8;
    else if (strncmp(entry, "BUSNUM=", 7) == 0) busnum = strtol(entry + 7, nullptr, 10);
    else if (strncmp(entry, "DEVNUM=", 7) == 0) devnum = strtol(entry + 7, nullptr, 10);
  }
  if (action == nullptr || devpath == nullptr || devtype == nullptr) return;

  const gboolean is_add = strcmp(action, "add") == 0;
  const gboolean is_remove = strcmp(action, "remove") == 0;
  if (!is_add && !is_remove) return;

  UeventMessage* message = nullptr;

  if (strcmp(devtype, "usb_interface") == 0 && interface_triplet != nullptr &&
      strtol(interface_triplet, nullptr, 10) == kUsbVideoClass) {
    // Video interface add/remove: the parent usb_device is the camera. Its
    // basename is the path component before the interface component.
    g_autofree gchar* parent = g_path_get_dirname(devpath);
    g_autofree gchar* name = g_path_get_basename(parent);
    message = g_new0(UeventMessage, 1);
    message->attached = is_add;
    message->video_interface = TRUE;
    g_strlcpy(message->device_name, name, sizeof(message->device_name));
  } else if (is_remove && strcmp(devtype, "usb_device") == 0) {
    // The usb_device removal ends the removal burst and carries the
    // identity; UeventIdle emits the detach from it.
    g_autofree gchar* name = g_path_get_basename(devpath);
    message = g_new0(UeventMessage, 1);
    message->attached = FALSE;
    g_strlcpy(message->device_name, name, sizeof(message->device_name));
    message->busnum = static_cast<int>(busnum);
    message->devnum = static_cast<int>(devnum);
    if (product != nullptr) {
      unsigned int vendor_id = 0;
      unsigned int product_id = 0;
      if (sscanf(product, "%x/%x", &vendor_id, &product_id) == 2) {
        message->vendor_id = static_cast<int>(vendor_id);
        message->product_id = static_cast<int>(product_id);
      }
    }
  }

  if (message != nullptr) {
    message->plugin = FLUTTER_FFI_UVC_PLUGIN(g_object_ref(self));
    g_idle_add(UeventIdle, message);
  }
}

gpointer UeventThreadFunc(gpointer user_data) {
  FlutterFfiUvcPlugin* self = FLUTTER_FFI_UVC_PLUGIN(user_data);
  char buffer[8192];
  struct pollfd fds[2];
  fds[0].fd = self->uevent_fd;
  fds[0].events = POLLIN;
  fds[1].fd = self->uevent_wakeup_pipe[0];
  fds[1].events = POLLIN;

  for (;;) {
    fds[0].revents = 0;
    fds[1].revents = 0;
    if (poll(fds, 2, -1) < 0) {
      if (errno == EINTR) continue;
      break;
    }
    if (fds[1].revents != 0) break;  // shutdown requested
    if ((fds[0].revents & POLLIN) == 0) continue;
    const ssize_t length = recv(self->uevent_fd, buffer, sizeof(buffer) - 1, 0);
    if (length <= 0) continue;
    buffer[length] = '\0';
    ProcessUevent(self, buffer, length);
  }
  return nullptr;
}

void StartDeviceNotifications(FlutterFfiUvcPlugin* self) {
  if (self->uevent_thread != nullptr) return;

  const int fd = socket(AF_NETLINK, SOCK_DGRAM | SOCK_CLOEXEC,
                        NETLINK_KOBJECT_UEVENT);
  if (fd < 0) return;
  struct sockaddr_nl address;
  memset(&address, 0, sizeof(address));
  address.nl_family = AF_NETLINK;
  address.nl_groups = 1;  // kernel uevent broadcast group
  if (bind(fd, reinterpret_cast<struct sockaddr*>(&address), sizeof(address)) <
      0) {
    close(fd);
    return;
  }
  if (pipe(self->uevent_wakeup_pipe) != 0) {
    close(fd);
    return;
  }
  self->uevent_fd = fd;
  self->uevent_thread =
      g_thread_new("ffi-uvc-uevent", UeventThreadFunc, self);
}

void StopDeviceNotifications(FlutterFfiUvcPlugin* self) {
  if (self->uevent_thread == nullptr) return;
  const char wake = 'q';
  if (write(self->uevent_wakeup_pipe[1], &wake, 1) < 0) {
    // Fall through; joining still succeeds once poll returns.
  }
  g_thread_join(self->uevent_thread);
  self->uevent_thread = nullptr;
  close(self->uevent_fd);
  self->uevent_fd = -1;
  close(self->uevent_wakeup_pipe[0]);
  close(self->uevent_wakeup_pipe[1]);
  self->uevent_wakeup_pipe[0] = -1;
  self->uevent_wakeup_pipe[1] = -1;
}

FlMethodErrorResponse* DeviceEventsListenCb(FlEventChannel* /*channel*/,
                                            FlValue* /*args*/,
                                            gpointer user_data) {
  FlutterFfiUvcPlugin* self = FLUTTER_FFI_UVC_PLUGIN(user_data);
  self->device_events_listening = TRUE;
  // Monitor first: the netlink socket queues events from the moment it is
  // bound, so a device that appears during the sysfs seed scan below is not
  // lost. A device both seeded and queued dedupes by deviceId in UeventIdle.
  StartDeviceNotifications(self);
  SeedKnownVideoDevices(self);
  return nullptr;
}

FlMethodErrorResponse* DeviceEventsCancelCb(FlEventChannel* /*channel*/,
                                            FlValue* /*args*/,
                                            gpointer user_data) {
  FlutterFfiUvcPlugin* self = FLUTTER_FFI_UVC_PLUGIN(user_data);
  self->device_events_listening = FALSE;
  StopDeviceNotifications(self);
  return nullptr;
}

// ---------------------------------------------------------------------------
// Channel plumbing
// ---------------------------------------------------------------------------

void TextureChannelCb(FlMethodChannel* /*channel*/, FlMethodCall* method_call,
                      gpointer user_data) {
  HandleTextureCall(FLUTTER_FFI_UVC_PLUGIN(user_data), method_call);
}

void UsbChannelCb(FlMethodChannel* /*channel*/, FlMethodCall* method_call,
                  gpointer user_data) {
  HandleUsbCall(FLUTTER_FFI_UVC_PLUGIN(user_data), method_call);
}

}  // namespace

static void flutter_ffi_uvc_plugin_dispose(GObject* object) {
  FlutterFfiUvcPlugin* self = FLUTTER_FFI_UVC_PLUGIN(object);

  StopDeviceNotifications(self);

  if (self->textures != nullptr) {
    GHashTableIter iter;
    gpointer key = nullptr;
    gpointer texture = nullptr;
    g_hash_table_iter_init(&iter, self->textures);
    while (g_hash_table_iter_next(&iter, &key, &texture)) {
      UnbindTexture(FFI_UVC_TEXTURE(texture));
      fl_texture_registrar_unregister_texture(self->texture_registrar,
                                              FL_TEXTURE(texture));
    }
    g_clear_pointer(&self->textures, g_hash_table_unref);
  }
  if (self->session_fds != nullptr) {
    // Close each native session before its fd, or libuvc's transfer threads
    // keep using a closed fd during engine teardown.
    GHashTableIter iter;
    gpointer key = nullptr;
    gpointer value = nullptr;
    g_hash_table_iter_init(&iter, self->session_fds);
    while (g_hash_table_iter_next(&iter, &key, &value)) {
      // A session leaked by Dart may already be destroyed by its finalizer.
      uvc_session_t* session = uvc_session_acquire_id(
          static_cast<uint64_t>(*static_cast<int64_t*>(key)));
      if (session != nullptr) {
        uvc_close_device(session);
        uvc_session_release(session);
      }
      close(GPOINTER_TO_INT(value) - 1);
    }
    g_clear_pointer(&self->session_fds, g_hash_table_unref);
  }
  g_clear_pointer(&self->known_video_devices, g_hash_table_unref);
  g_clear_object(&self->device_event_channel);

  G_OBJECT_CLASS(flutter_ffi_uvc_plugin_parent_class)->dispose(object);
}

static void flutter_ffi_uvc_plugin_class_init(FlutterFfiUvcPluginClass* klass) {
  G_OBJECT_CLASS(klass)->dispose = flutter_ffi_uvc_plugin_dispose;
}

static void flutter_ffi_uvc_plugin_init(FlutterFfiUvcPlugin* self) {
  self->uevent_fd = -1;
  self->uevent_wakeup_pipe[0] = -1;
  self->uevent_wakeup_pipe[1] = -1;
  self->textures =
      g_hash_table_new_full(Int64Hash, Int64Equal, g_free, g_object_unref);
  self->session_fds = g_hash_table_new_full(Int64Hash, Int64Equal, g_free, nullptr);
  self->known_video_devices =
      g_hash_table_new_full(g_str_hash, g_str_equal, g_free, g_free);
}

void flutter_ffi_uvc_plugin_register_with_registrar(
    FlPluginRegistrar* registrar) {
  FlutterFfiUvcPlugin* plugin = FLUTTER_FFI_UVC_PLUGIN(
      g_object_new(flutter_ffi_uvc_plugin_get_type(), nullptr));

  plugin->texture_registrar = fl_plugin_registrar_get_texture_registrar(registrar);
  FlBinaryMessenger* messenger = fl_plugin_registrar_get_messenger(registrar);
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();

  // The messenger keeps method channels alive while a handler is set; the
  // handler refs keep the plugin alive until engine shutdown.
  g_autoptr(FlMethodChannel) texture_channel = fl_method_channel_new(
      messenger, "flutter_ffi_uvc/texture", FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(texture_channel, TextureChannelCb,
                                            g_object_ref(plugin),
                                            g_object_unref);

  g_autoptr(FlMethodChannel) usb_channel = fl_method_channel_new(
      messenger, "flutter_ffi_uvc/usb", FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(usb_channel, UsbChannelCb,
                                            g_object_ref(plugin),
                                            g_object_unref);

  plugin->device_event_channel = fl_event_channel_new(
      messenger, "flutter_ffi_uvc/device_events", FL_METHOD_CODEC(codec));
  fl_event_channel_set_stream_handlers(plugin->device_event_channel,
                                       DeviceEventsListenCb,
                                       DeviceEventsCancelCb, plugin, nullptr);

  g_object_unref(plugin);
}
