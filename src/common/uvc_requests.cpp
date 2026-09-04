// Request queue shared by every backend. Builds the asynchronous lifecycle
// of the ABI (uvc_request_*) on the synchronous calls a backend implements
// (uvc_open_fd, uvc_start_preview, uvc_stop_preview, uvc_close_device).
//
// One detached worker thread per session, started on the first request.
// State lives in a process-wide table keyed by session id, so backends keep
// no field for it. The worker runs the teardown request last and frees the
// session through uvc_session_finalize, so no caller ever joins it.
//
// Locks: State::mutex guards the queue and flags and is never held while a
// backend call or a listener runs. State::listener_mutex is held while the
// request listener runs. g_platform.mutex is held while a platform
// callback runs. g_states_mutex is a leaf lock for the table.

#include "uvc_requests_internal.h"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdio>
#include <cstring>
#include <deque>
#include <map>
#include <memory>
#include <mutex>
#include <set>
#include <string>
#include <thread>
#include <vector>

namespace {

constexpr int kErrorInvalidParam = -2;  // UVC_ERROR_INVALID_PARAM
constexpr int kErrorNoDevice = -4;      // UVC_ERROR_NO_DEVICE
constexpr int kErrorInterrupted = -10;  // UVC_ERROR_INTERRUPTED
constexpr int kFormatMjpeg = 7;         // UVC_FRAME_FORMAT_MJPEG
constexpr int kFormatH264 = 8;          // UVC_FRAME_FORMAT_H264
constexpr size_t kResultsKept = 8;
constexpr int kVerifyPollMs = 20;

struct Request {
  int64_t id = 0;
  int op = 0;
  uvc_mode_t mode = {};
  int policy = UVC_VERIFY_NONE;
  int consecutive_frames = 0;
  int timeout_ms = 0;
  // Auto.
  bool modes_given = false;
  std::vector<uvc_mode_t> modes;
  int prefer_quality = 0;
  int max_candidates = 0;
  // Destroy only. Zero for a teardown whose caller is already gone.
  bool notify = true;
};

struct State {
  uvc_session_t *session = nullptr;
  uint64_t session_id = 0;

  std::mutex mutex;
  std::condition_variable cv;
  std::deque<Request> queue;
  bool worker_started = false;
  bool shutting_down = false;
  int64_t latest_id = 0;
  // Stop and close requests queued and not yet started. A start in
  // progress ends its verification while this is non-zero.
  int pending_interrupts = 0;
  // Close requests among them. An open waiting for its fd gives up while
  // this is non-zero. A stop leaves opens alone.
  int pending_closes = 0;
  // Open requests queued or waiting, with the fd supplied for them. -2
  // means none supplied yet (-1 is a supplied failure).
  std::map<int64_t, int> open_fds;
  // The fd the device currently uses, by the open request that took it.
  int64_t held_request = 0;
  std::map<int64_t, std::string> results;

  std::mutex listener_mutex;
  uvc_request_listener_t listener = nullptr;
  void *listener_data = nullptr;
};

struct PlatformListener {
  std::mutex mutex;
  uvc_platform_listener_t callbacks = {};
  void *user_data = nullptr;
};

// Request ids are unique for the life of the process and never reused, so
// a platform plugin can key its own state by a request id alone, the same
// way it does for session ids.
std::atomic<int64_t> g_next_request_id{1};

std::mutex g_states_mutex;
std::map<uint64_t, std::shared_ptr<State>> g_states;
// Ids that went through shutdown. A request for one of them after that
// gets no new worker for a session about to be freed.
std::set<uint64_t> g_shut_down;
PlatformListener g_platform;

std::shared_ptr<State> FindState(uvc_session_t *session, bool create) {
  if (session == nullptr) return nullptr;
  const uint64_t id = uvc_session_id(session);
  if (id == 0) return nullptr;
  std::lock_guard<std::mutex> lock(g_states_mutex);
  auto it = g_states.find(id);
  if (it != g_states.end()) return it->second;
  if (!create || g_shut_down.count(id) != 0) return nullptr;
  auto state = std::make_shared<State>();
  state->session = session;
  state->session_id = id;
  g_states[id] = state;
  return state;
}

void NotifyDeviceReleased(uint64_t session_id, int64_t request_id) {
  std::lock_guard<std::mutex> lock(g_platform.mutex);
  if (g_platform.callbacks.device_released != nullptr) {
    g_platform.callbacks.device_released(g_platform.user_data, session_id,
                                         request_id);
  }
}

void NotifySessionDestroyed(uint64_t session_id) {
  std::lock_guard<std::mutex> lock(g_platform.mutex);
  if (g_platform.callbacks.session_destroyed != nullptr) {
    g_platform.callbacks.session_destroyed(g_platform.user_data, session_id);
  }
}

// Closes the device and hands its fd back to the platform. Caller does not
// hold State::mutex.
void CloseDeviceAndRelease(State &st) {
  uvc_close_device(st.session);
  int64_t released = 0;
  {
    std::lock_guard<std::mutex> lock(st.mutex);
    released = st.held_request;
    st.held_request = 0;
  }
  if (released != 0) NotifyDeviceReleased(st.session_id, released);
}

void AppendJsonString(std::string &out, const char *text) {
  out.push_back('"');
  for (const char *p = text; p != nullptr && *p != '\0'; ++p) {
    const unsigned char c = static_cast<unsigned char>(*p);
    switch (c) {
      case '"': out += "\\\""; break;
      case '\\': out += "\\\\"; break;
      case '\n': out += "\\n"; break;
      case '\r': out += "\\r"; break;
      case '\t': out += "\\t"; break;
      default:
        if (c < 0x20) {
          char buf[8];
          snprintf(buf, sizeof(buf), "\\u%04x", c);
          out += buf;
        } else {
          out.push_back(static_cast<char>(c));
        }
    }
  }
  out.push_back('"');
}

struct StartOutcome {
  bool success = false;
  int64_t valid_frames = 0;
  int64_t consecutive = 0;
  int64_t errors = 0;
  int64_t elapsed_ms = 0;
  std::string last_error;
  int native_code = 0;
};

std::string StartJson(const uvc_mode_t &mode, const StartOutcome &o) {
  std::string json = "{\"success\":";
  json += o.success ? "true" : "false";
  char buf[256];
  snprintf(buf, sizeof(buf),
           ",\"validFrameCount\":%lld,\"consecutiveValidFrames\":%lld,"
           "\"errorCount\":%lld,\"elapsedMs\":%lld,\"nativeErrorCode\":%d,"
           "\"frameFormat\":%d,\"width\":%d,\"height\":%d,\"fps\":%d,"
           "\"lastError\":",
           static_cast<long long>(o.valid_frames),
           static_cast<long long>(o.consecutive),
           static_cast<long long>(o.errors),
           static_cast<long long>(o.elapsed_ms), o.native_code,
           mode.frame_format, mode.width, mode.height, mode.fps);
  json += buf;
  if (o.last_error.empty()) {
    json += "null";
  } else {
    AppendJsonString(json, o.last_error.c_str());
  }
  json += "}";
  return json;
}

int64_t ElapsedMs(std::chrono::steady_clock::time_point since) {
  return std::chrono::duration_cast<std::chrono::milliseconds>(
             std::chrono::steady_clock::now() - since)
      .count();
}

bool Interrupted(State &st) {
  std::lock_guard<std::mutex> lock(st.mutex);
  return st.pending_interrupts > 0 || st.shutting_down;
}

StartOutcome InterruptedOutcome(std::chrono::steady_clock::time_point since,
                                const StartOutcome &partial) {
  StartOutcome o = partial;
  o.success = false;
  o.elapsed_ms = ElapsedMs(since);
  o.last_error = "Preview start interrupted by a later lifecycle call";
  o.native_code = kErrorInterrupted;
  return o;
}

// Starts the stream and verifies it. Runs on the worker.
StartOutcome RunStart(State &st, const Request &r) {
  StartOutcome o;
  const auto since = std::chrono::steady_clock::now();
  uvc_session_t *s = st.session;
  const int started = uvc_start_preview(s, r.mode.frame_format, r.mode.width,
                                        r.mode.height, r.mode.fps);
  if (started != 0) {
    o.elapsed_ms = ElapsedMs(since);
    o.last_error = uvc_last_error(s);
    o.native_code = started;
    return o;
  }
  if (r.policy == UVC_VERIFY_NONE) {
    o.success = true;
    o.elapsed_ms = ElapsedMs(since);
    return o;
  }

  int64_t errors_seen = uvc_error_count(s);
  int64_t last_sequence = uvc_latest_frame_sequence(s);
  const int required = r.consecutive_frames > 0 ? r.consecutive_frames : 1;
  for (;;) {
    if (Interrupted(st)) return InterruptedOutcome(since, o);

    const int64_t errors_now = uvc_error_count(s);
    if (errors_now != errors_seen) {
      o.errors += errors_now - errors_seen;
      errors_seen = errors_now;
      last_sequence = uvc_latest_frame_sequence(s);
      o.consecutive = 0;
      o.last_error = uvc_last_error(s);
    }
    const int64_t sequence = uvc_latest_frame_sequence(s);
    const int64_t delta = sequence - last_sequence;
    if (delta > 0) {
      o.valid_frames += delta;
      o.consecutive += delta;
      last_sequence = sequence;
      if (r.policy == UVC_VERIFY_SEQUENCE_ONLY || o.consecutive >= required) {
        o.success = true;
        o.elapsed_ms = ElapsedMs(since);
        return o;
      }
    }
    if (ElapsedMs(since) >= r.timeout_ms) break;
    std::unique_lock<std::mutex> lock(st.mutex);
    st.cv.wait_for(lock, std::chrono::milliseconds(kVerifyPollMs), [&] {
      return st.pending_interrupts > 0 || st.shutting_down;
    });
  }

  if (Interrupted(st)) return InterruptedOutcome(since, o);
  uvc_stop_preview(s);
  o.elapsed_ms = ElapsedMs(since);
  if (o.last_error.empty()) o.last_error = uvc_last_error(s);
  return o;
}

std::vector<uvc_mode_t> DefaultCandidates(uvc_session_t *s, int prefer_quality,
                                          int max_candidates) {
  std::vector<uvc_mode_t> modes(256);
  const int count = uvc_get_supported_modes(s, modes.data(),
                                            static_cast<int>(modes.size()));
  modes.resize(count > 0 ? count : 0);
  modes.erase(std::remove_if(modes.begin(), modes.end(),
                             [](const uvc_mode_t &m) {
                               return m.frame_format == kFormatH264;
                             }),
              modes.end());
  const int direction = prefer_quality ? -1 : 1;
  std::stable_sort(modes.begin(), modes.end(),
                   [direction](const uvc_mode_t &a, const uvc_mode_t &b) {
                     const int fa = a.frame_format == kFormatMjpeg ? 0 : 1;
                     const int fb = b.frame_format == kFormatMjpeg ? 0 : 1;
                     if (fa != fb) return fa < fb;
                     const long long area_a = 1LL * a.width * a.height;
                     const long long area_b = 1LL * b.width * b.height;
                     if (area_a != area_b) {
                       return direction > 0 ? area_a < area_b : area_a > area_b;
                     }
                     return direction > 0 ? a.fps < b.fps : a.fps > b.fps;
                   });
  if (max_candidates > 0 && modes.size() > static_cast<size_t>(max_candidates)) {
    modes.resize(static_cast<size_t>(max_candidates));
  }
  return modes;
}

// Tries candidates until one verifies. Runs on the worker.
std::string RunAuto(State &st, const Request &r, int *out_result) {
  std::vector<uvc_mode_t> modes =
      r.modes_given ? r.modes
                    : DefaultCandidates(st.session, r.prefer_quality,
                                        r.max_candidates);
  std::string json = "{\"attempts\":[";
  bool first = true;
  // Trying no candidate means the app moved on, which is interrupted.
  int result = kErrorInterrupted;
  for (const uvc_mode_t &mode : modes) {
    {
      std::lock_guard<std::mutex> lock(st.mutex);
      // A later request of any kind means the app moved on.
      if (st.latest_id != r.id || st.shutting_down) break;
    }
    Request one = r;
    one.mode = mode;
    const StartOutcome o = RunStart(st, one);
    if (!first) json += ",";
    first = false;
    json += StartJson(mode, o);
    result = o.native_code;
    if (o.success || o.native_code == kErrorInterrupted ||
        o.native_code == kErrorNoDevice) {
      break;
    }
  }
  json += "]}";
  *out_result = result;
  return json;
}

void StoreResult(State &st, int64_t id, std::string json) {
  std::lock_guard<std::mutex> lock(st.mutex);
  st.results[id] = std::move(json);
  while (st.results.size() > kResultsKept) st.results.erase(st.results.begin());
}

void Complete(State &st, const Request &r, int result) {
  std::lock_guard<std::mutex> lock(st.listener_mutex);
  if (st.listener != nullptr) st.listener(st.listener_data, r.id, r.op, result);
}

// Runs the open: closes the current device, waits for the fd, opens it.
int RunOpen(State &st, const Request &r) {
  CloseDeviceAndRelease(st);
  int fd = -2;
  {
    std::unique_lock<std::mutex> lock(st.mutex);
    st.cv.wait(lock, [&] {
      return st.pending_closes > 0 || st.shutting_down ||
             st.open_fds[r.id] != -2;
    });
    fd = st.open_fds[r.id];
    st.open_fds.erase(r.id);
    if (fd == -2) {
      // Gave up waiting. A later supply is refused.
      return st.shutting_down ? kErrorNoDevice : kErrorInterrupted;
    }
  }
  // A supplied fd is opened even with a close queued behind. The close
  // then takes the device back, in the order the caller asked for.
  if (fd < 0) return kErrorNoDevice;
  const int result = uvc_open_fd(st.session, fd);
  if (result != 0) {
    NotifyDeviceReleased(st.session_id, r.id);
    return result;
  }
  std::lock_guard<std::mutex> lock(st.mutex);
  st.held_request = r.id;
  return 0;
}

// Last request of a session. Drains what is left, closes the device, and
// frees the session. Runs on the worker, so waiting here never blocks a
// caller that a native thread may be reporting into.
void RunDestroy(const std::shared_ptr<State> &state, const Request &r) {
  State &st = *state;
  uvc_session_t *session = st.session;
  const uint64_t id = st.session_id;

  std::deque<Request> leftover;
  std::vector<int64_t> unused_fds;
  {
    std::lock_guard<std::mutex> lock(st.mutex);
    leftover.swap(st.queue);
    for (const auto &entry : st.open_fds) {
      if (entry.second >= 0) unused_fds.push_back(entry.first);
    }
    st.open_fds.clear();
    st.results.clear();
  }
  for (int64_t request : unused_fds) NotifyDeviceReleased(id, request);
  for (const Request &queued : leftover) Complete(st, queued, kErrorNoDevice);

  CloseDeviceAndRelease(st);
  // The device is closed, so no callback can be in flight and clearing the
  // slot returns at once.
  uvc_set_error_listener(session, nullptr, nullptr);
  // Clear the slot before reporting. The caller frees its callable as soon
  // as it hears, and nothing may reach the old pointer after that.
  uvc_request_listener_t listener = nullptr;
  void *listener_data = nullptr;
  {
    std::lock_guard<std::mutex> lock(st.listener_mutex);
    listener = st.listener;
    listener_data = st.listener_data;
    st.listener = nullptr;
    st.listener_data = nullptr;
  }
  if (listener != nullptr) listener(listener_data, r.id, r.op, 0);
  {
    std::lock_guard<std::mutex> lock(g_states_mutex);
    g_states.erase(id);
  }
  uvc_session_finalize(session);
  NotifySessionDestroyed(id);
}

void WorkerMain(std::shared_ptr<State> state) {
  State &st = *state;
  for (;;) {
    Request r;
    {
      std::unique_lock<std::mutex> lock(st.mutex);
      st.cv.wait(lock, [&] { return !st.queue.empty(); });
      r = std::move(st.queue.front());
      st.queue.pop_front();
      if (r.op == UVC_REQUEST_STOP || r.op == UVC_REQUEST_CLOSE) {
        st.pending_interrupts -= 1;
      }
      if (r.op == UVC_REQUEST_CLOSE) st.pending_closes -= 1;
    }
    if (r.op == UVC_REQUEST_DESTROY) {
      RunDestroy(state, r);
      return;
    }
    bool draining = false;
    {
      std::lock_guard<std::mutex> lock(st.mutex);
      draining = st.shutting_down;
    }
    if (draining) {
      // Queued ahead of a teardown, so it never reaches the device. Its fd,
      // if one was supplied, goes back in RunDestroy.
      Complete(st, r, kErrorNoDevice);
      continue;
    }
    int result = 0;
    switch (r.op) {
      case UVC_REQUEST_OPEN:
        result = RunOpen(st, r);
        break;
      case UVC_REQUEST_START: {
        const StartOutcome o = RunStart(st, r);
        StoreResult(st, r.id, StartJson(r.mode, o));
        result = o.native_code;
        break;
      }
      case UVC_REQUEST_START_AUTO: {
        std::string json = RunAuto(st, r, &result);
        StoreResult(st, r.id, std::move(json));
        break;
      }
      case UVC_REQUEST_STOP:
        uvc_stop_preview(st.session);
        break;
      case UVC_REQUEST_CLOSE:
        CloseDeviceAndRelease(st);
        break;
      default:
        result = kErrorInvalidParam;
    }
    Complete(st, r, result);
  }
}

// Queues r and returns its id. Caller does not hold State::mutex.
int64_t Enqueue(const std::shared_ptr<State> &state, Request r) {
  State &st = *state;
  std::lock_guard<std::mutex> lock(st.mutex);
  if (st.shutting_down && r.op != UVC_REQUEST_DESTROY) return kErrorNoDevice;
  r.id = g_next_request_id.fetch_add(1);
  st.latest_id = r.id;
  if (r.op == UVC_REQUEST_STOP || r.op == UVC_REQUEST_CLOSE) {
    st.pending_interrupts += 1;
  }
  if (r.op == UVC_REQUEST_CLOSE) st.pending_closes += 1;
  if (r.op == UVC_REQUEST_OPEN) st.open_fds[r.id] = -2;
  if (r.op == UVC_REQUEST_DESTROY) {
    // Interrupts whatever is running and refuses everything after it.
    st.shutting_down = true;
    st.pending_interrupts += 1;
    st.pending_closes += 1;
  }
  st.queue.push_back(std::move(r));
  if (!st.worker_started) {
    st.worker_started = true;
    std::thread(WorkerMain, state).detach();
  }
  st.cv.notify_all();
  return st.latest_id;
}

// Queues the one teardown a session gets. Returns its request id, or a
// negative code when the pointer is not a live session or a teardown is
// already under way.
int64_t QueueDestroy(uvc_session_t *session, bool notify) {
  if (session == nullptr) return kErrorInvalidParam;
  // Validates the pointer against the registry, as the synchronous destroy
  // used to. Anything else is not ours to free.
  if (uvc_session_acquire(session) == 0) return kErrorInvalidParam;
  const uint64_t id = uvc_session_id(session);
  // A session that never made a request gets a worker here, so teardown
  // never runs on the caller's thread.
  std::shared_ptr<State> state = FindState(session, true);
  bool first = false;
  {
    std::lock_guard<std::mutex> lock(g_states_mutex);
    first = g_shut_down.insert(id).second;
  }
  uvc_session_release(session);
  if (!state || !first) return kErrorNoDevice;
  if (!notify) {
    // Nobody is left to hear from this session, and the worker still has
    // the queue to walk.
    std::lock_guard<std::mutex> lock(state->listener_mutex);
    state->listener = nullptr;
    state->listener_data = nullptr;
  }
  Request r;
  r.op = UVC_REQUEST_DESTROY;
  r.notify = notify;
  return Enqueue(state, std::move(r));
}

int64_t EnqueueStart(uvc_session_t *session, int64_t expected_latest,
                     uvc_mode_t mode, int policy, int consecutive_frames,
                     int timeout_ms) {
  std::shared_ptr<State> state = FindState(session, true);
  if (!state) return kErrorInvalidParam;
  if (policy < UVC_VERIFY_NONE || policy > UVC_VERIFY_SEQUENCE_ONLY ||
      timeout_ms < 0) {
    return kErrorInvalidParam;
  }
  if (expected_latest != 0) {
    std::lock_guard<std::mutex> lock(state->mutex);
    if (state->latest_id != expected_latest) return kErrorInterrupted;
  }
  Request r;
  r.op = UVC_REQUEST_START;
  r.mode = mode;
  r.policy = policy;
  r.consecutive_frames = consecutive_frames;
  r.timeout_ms = timeout_ms;
  return Enqueue(state, std::move(r));
}

}  // namespace

extern "C" {

FFI_PLUGIN_EXPORT void uvc_set_request_listener(uvc_session_t *session,
                                                uvc_request_listener_t listener,
                                                void *user_data) {
  std::shared_ptr<State> state = FindState(session, listener != nullptr);
  if (!state) return;
  std::lock_guard<std::mutex> lock(state->listener_mutex);
  state->listener = listener;
  state->listener_data = listener != nullptr ? user_data : nullptr;
}

FFI_PLUGIN_EXPORT int64_t uvc_request_open(uvc_session_t *session) {
  std::shared_ptr<State> state = FindState(session, true);
  if (!state) return kErrorInvalidParam;
  Request r;
  r.op = UVC_REQUEST_OPEN;
  return Enqueue(state, std::move(r));
}

FFI_PLUGIN_EXPORT int uvc_supply_fd(uvc_session_t *session, int64_t request_id,
                                    int fd) {
  std::shared_ptr<State> state = FindState(session, false);
  if (!state) return kErrorInvalidParam;
  std::lock_guard<std::mutex> lock(state->mutex);
  auto it = state->open_fds.find(request_id);
  if (it == state->open_fds.end() || it->second != -2 || state->shutting_down) {
    return kErrorInvalidParam;
  }
  it->second = fd < 0 ? -1 : fd;
  state->cv.notify_all();
  return 0;
}

FFI_PLUGIN_EXPORT int64_t uvc_request_start(uvc_session_t *session,
                                            uvc_mode_t mode, int policy,
                                            int consecutive_frames,
                                            int timeout_ms) {
  return EnqueueStart(session, 0, mode, policy, consecutive_frames, timeout_ms);
}

FFI_PLUGIN_EXPORT int64_t uvc_request_start_if(uvc_session_t *session,
                                               int64_t expected_latest,
                                               uvc_mode_t mode, int policy,
                                               int consecutive_frames,
                                               int timeout_ms) {
  return EnqueueStart(session, expected_latest, mode, policy,
                      consecutive_frames, timeout_ms);
}

FFI_PLUGIN_EXPORT int64_t uvc_request_start_auto(
    uvc_session_t *session, const uvc_mode_t *modes, int mode_count,
    int prefer_quality, int max_candidates, int policy, int consecutive_frames,
    int timeout_ms) {
  std::shared_ptr<State> state = FindState(session, true);
  if (!state) return kErrorInvalidParam;
  if (policy < UVC_VERIFY_NONE || policy > UVC_VERIFY_SEQUENCE_ONLY ||
      timeout_ms < 0 || (modes == nullptr && mode_count > 0) ||
      mode_count < 0) {
    return kErrorInvalidParam;
  }
  Request r;
  r.op = UVC_REQUEST_START_AUTO;
  r.modes_given = modes != nullptr;
  if (modes != nullptr) r.modes.assign(modes, modes + mode_count);
  r.prefer_quality = prefer_quality;
  r.max_candidates = max_candidates;
  r.policy = policy;
  r.consecutive_frames = consecutive_frames;
  r.timeout_ms = timeout_ms;
  return Enqueue(state, std::move(r));
}

FFI_PLUGIN_EXPORT int64_t uvc_request_stop(uvc_session_t *session) {
  std::shared_ptr<State> state = FindState(session, true);
  if (!state) return kErrorInvalidParam;
  Request r;
  r.op = UVC_REQUEST_STOP;
  return Enqueue(state, std::move(r));
}

FFI_PLUGIN_EXPORT int64_t uvc_request_close(uvc_session_t *session) {
  std::shared_ptr<State> state = FindState(session, true);
  if (!state) return kErrorInvalidParam;
  Request r;
  r.op = UVC_REQUEST_CLOSE;
  return Enqueue(state, std::move(r));
}

FFI_PLUGIN_EXPORT int64_t uvc_request_destroy(uvc_session_t *session) {
  return QueueDestroy(session, true);
}

FFI_PLUGIN_EXPORT int64_t uvc_latest_request_id(uvc_session_t *session) {
  std::shared_ptr<State> state = FindState(session, false);
  if (!state) return 0;
  std::lock_guard<std::mutex> lock(state->mutex);
  return state->latest_id;
}

FFI_PLUGIN_EXPORT int uvc_take_request_result_json(uvc_session_t *session,
                                                   int64_t request_id,
                                                   uint8_t *buffer,
                                                   int buffer_length) {
  std::shared_ptr<State> state = FindState(session, false);
  if (!state || buffer == nullptr || buffer_length <= 0) return 0;
  std::lock_guard<std::mutex> lock(state->mutex);
  auto it = state->results.find(request_id);
  if (it == state->results.end()) return 0;
  const std::string &json = it->second;
  // Kept when it does not fit, so a larger buffer can fetch it.
  if (json.size() >= static_cast<size_t>(buffer_length)) return 0;
  memcpy(buffer, json.data(), json.size());
  buffer[json.size()] = 0;
  const int written = static_cast<int>(json.size());
  state->results.erase(it);
  return written;
}

FFI_PLUGIN_EXPORT void uvc_set_platform_listener(
    const uvc_platform_listener_t *listener, void *user_data) {
  std::lock_guard<std::mutex> lock(g_platform.mutex);
  if (listener == nullptr) {
    g_platform.callbacks = uvc_platform_listener_t{};
    g_platform.user_data = nullptr;
  } else {
    g_platform.callbacks = *listener;
    g_platform.user_data = user_data;
  }
}

void uvc_requests_destroy(uvc_session_t *session, int notify) {
  QueueDestroy(session, notify != 0);
}

}  // extern "C"
