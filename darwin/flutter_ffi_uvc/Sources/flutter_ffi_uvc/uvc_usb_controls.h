#ifndef FLUTTER_FFI_UVC_MACOS_UVC_USB_CONTROLS_H_
#define FLUTTER_FFI_UVC_MACOS_UVC_USB_CONTROLS_H_

// UVC class requests over IOKit. AVFoundation streams the camera but exposes
// none of its UVC controls, so they go to the VideoControl interface as
// control transfers on endpoint 0. The device is never opened or claimed,
// which leaves the system UVC driver and the running stream untouched.
//
// A sandboxed app needs the com.apple.security.device.usb entitlement.
// Without it Open fails and the session streams with no controls.

#include <cstdint>
#include <memory>
#include <string>

namespace uvc_mac {

// UVC request codes.
constexpr uint8_t kUvcSetCur = 0x01;
constexpr uint8_t kUvcGetCur = 0x81;
constexpr uint8_t kUvcGetMin = 0x82;
constexpr uint8_t kUvcGetMax = 0x83;
constexpr uint8_t kUvcGetRes = 0x84;
constexpr uint8_t kUvcGetDef = 0x87;

struct UsbIds {
  // USB location id, valid when has_location is set.
  uint32_t location = 0;
  bool has_location = false;
  uint16_t vendor_id = 0;
  uint16_t product_id = 0;
};

class UsbControlDevice {
 public:
  // Finds the USB device and reads its VideoControl descriptors. Returns
  // null and fills error when the device cannot be reached.
  static std::unique_ptr<UsbControlDevice> Open(const UsbIds& ids,
                                                std::string* error);
  ~UsbControlDevice();

  UsbControlDevice(const UsbControlDevice&) = delete;
  UsbControlDevice& operator=(const UsbControlDevice&) = delete;

  // Descriptor bmControls of the camera terminal and the processing unit,
  // in the bit order of the UVC specification. Zero when the unit is absent.
  uint64_t camera_terminal_controls() const { return ct_controls_; }
  uint64_t processing_unit_controls() const { return pu_controls_; }

  // Sends one class request to the camera terminal (is_ct) or the
  // processing unit. Returns 0 or a negative libuvc-style error code. Not
  // thread-safe, the caller serializes.
  int Request(bool is_ct, uint8_t selector, uint8_t request, uint8_t* data,
              uint16_t length);

 private:
  UsbControlDevice() = default;

  // IOUSBDeviceInterface**, kept opaque so this header stays free of IOKit.
  void* device_ = nullptr;
  int interface_number_ = -1;
  int camera_terminal_id_ = -1;
  int processing_unit_id_ = -1;
  uint64_t ct_controls_ = 0;
  uint64_t pu_controls_ = 0;
};

}  // namespace uvc_mac

#endif  // FLUTTER_FFI_UVC_MACOS_UVC_USB_CONTROLS_H_
