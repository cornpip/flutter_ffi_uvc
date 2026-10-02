// Exception guards for the C ABI. No C++ exception may unwind across the C
// ABI into Dart, the C backend, or a system callback (the process would
// abort), so every export runs its body through one of these guards or a
// function try block that returns uvc_guard::CurrentExceptionCode().
#ifndef FLUTTER_FFI_UVC_GUARD_H_
#define FLUTTER_FFI_UVC_GUARD_H_

#include <new>

namespace uvc_guard {

// Native error code for the exception being handled. Call only from a catch.
// Flutter builds Windows plugins with _HAS_EXCEPTIONS=0, where std::bad_alloc
// names a different type than the one operator new throws, so an allocation
// failure reports UVC_ERROR_OTHER there.
inline int CurrentExceptionCode() noexcept {
  try {
    throw;
  } catch (const std::bad_alloc &) {
    return -11;  // UVC_ERROR_NO_MEM
  } catch (...) {
    return -99;  // UVC_ERROR_OTHER
  }
}

// Returns the body's result, or the error code of an escaped exception.
template <typename Fn>
auto GuardedCode(Fn &&body) noexcept -> decltype(body()) {
  try {
    return body();
  } catch (...) {
    return CurrentExceptionCode();
  }
}

// Returns the body's result, or [fallback] when an exception escapes.
template <typename R, typename Fn>
R GuardedOr(R fallback, Fn &&body) noexcept {
  try {
    return body();
  } catch (...) {
    return fallback;
  }
}

template <typename Fn>
void GuardedVoid(Fn &&body) noexcept {
  try {
    body();
  } catch (...) {
  }
}

}  // namespace uvc_guard

#endif  // FLUTTER_FFI_UVC_GUARD_H_
