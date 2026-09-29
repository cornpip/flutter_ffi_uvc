#include "uvc_usb_controls.h"

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/usb/IOUSBLib.h>

#include <cstdio>
#include <cstring>

namespace uvc_mac {

namespace {

// libuvc uvc_error_t codes.
constexpr int kErrorIo = -1;
constexpr int kErrorAccess = -3;
constexpr int kErrorNoDevice = -4;
constexpr int kErrorTimeout = -7;
constexpr int kErrorPipe = -9;
constexpr int kErrorNotSupported = -12;

constexpr uint8_t kClassVideo = 14;
constexpr uint8_t kSubclassVideoControl = 1;
constexpr uint8_t kDescriptorInterface = 0x04;
constexpr uint8_t kDescriptorCsInterface = 0x24;
constexpr uint8_t kVcInputTerminal = 0x02;
constexpr uint8_t kVcProcessingUnit = 0x05;
constexpr int kTerminalTypeCamera = 0x0201;

constexpr uint32_t kRequestTimeoutMs = 1000;

uint32_t RegistryU32(io_service_t service, CFStringRef key) {
  uint32_t out = 0;
  CFTypeRef ref =
      IORegistryEntryCreateCFProperty(service, key, kCFAllocatorDefault, 0);
  if (ref != nullptr) {
    if (CFGetTypeID(ref) == CFNumberGetTypeID()) {
      CFNumberGetValue(static_cast<CFNumberRef>(ref), kCFNumberSInt32Type,
                       &out);
    }
    CFRelease(ref);
  }
  return out;
}

// Returns the matching device with a reference the caller releases. With a
// location id the match is exact. Without one it succeeds only when a single
// device carries the vendor and product id.
io_service_t FindDevice(const UsbIds& ids) {
  io_iterator_t it = IO_OBJECT_NULL;
  // MACH_PORT_NULL is the default main port under either of its SDK names.
  if (IOServiceGetMatchingServices(MACH_PORT_NULL,
                                   IOServiceMatching("IOUSBHostDevice"),
                                   &it) != KERN_SUCCESS) {
    return IO_OBJECT_NULL;
  }
  io_service_t exact = IO_OBJECT_NULL;
  io_service_t by_ids = IO_OBJECT_NULL;
  int by_ids_count = 0;
  io_service_t service;
  while ((service = IOIteratorNext(it)) != IO_OBJECT_NULL) {
    const bool ids_match =
        RegistryU32(service, CFSTR("idVendor")) == ids.vendor_id &&
        RegistryU32(service, CFSTR("idProduct")) == ids.product_id;
    if (ids_match && ids.has_location &&
        RegistryU32(service, CFSTR("locationID")) == ids.location) {
      exact = service;
      break;
    }
    if (ids_match) {
      by_ids_count += 1;
      if (by_ids == IO_OBJECT_NULL) {
        by_ids = service;
        continue;
      }
    }
    IOObjectRelease(service);
  }
  IOObjectRelease(it);
  if (exact != IO_OBJECT_NULL) {
    if (by_ids != IO_OBJECT_NULL) IOObjectRelease(by_ids);
    return exact;
  }
  if (by_ids_count == 1) return by_ids;
  if (by_ids != IO_OBJECT_NULL) IOObjectRelease(by_ids);
  return IO_OBJECT_NULL;
}

uint64_t Bitmap(const uint8_t* bytes, size_t size) {
  uint64_t out = 0;
  for (size_t i = 0; i < size && i < 8; ++i) {
    out |= static_cast<uint64_t>(bytes[i]) << (8 * i);
  }
  return out;
}

int MapReturn(IOReturn kr) {
  switch (kr) {
    case kIOReturnSuccess:
      return 0;
    case kIOUSBPipeStalled:
      return kErrorPipe;
    case kIOUSBTransactionTimeout:
    case kIOReturnTimeout:
      return kErrorTimeout;
    case kIOReturnNoDevice:
    case kIOReturnNotResponding:
    case kIOReturnNotAttached:
      return kErrorNoDevice;
    case kIOReturnNotPermitted:
    case kIOReturnNotPrivileged:
    case kIOReturnExclusiveAccess:
      return kErrorAccess;
    case kIOReturnUnsupported:
      return kErrorNotSupported;
    default:
      return kErrorIo;
  }
}

}  // namespace

std::unique_ptr<UsbControlDevice> UsbControlDevice::Open(const UsbIds& ids,
                                                         std::string* error) {
  auto fail = [error](const char* message) {
    if (error != nullptr) *error = message;
    return std::unique_ptr<UsbControlDevice>();
  };

  io_service_t service = FindDevice(ids);
  if (service == IO_OBJECT_NULL) {
    return fail("USB device of the camera not found");
  }
  IOCFPlugInInterface** plugin = nullptr;
  SInt32 score = 0;
  const kern_return_t kr = IOCreatePlugInInterfaceForService(
      service, kIOUSBDeviceUserClientTypeID, kIOCFPlugInInterfaceID, &plugin,
      &score);
  IOObjectRelease(service);
  if (kr != KERN_SUCCESS || plugin == nullptr) {
    return fail(
        "USB access to the camera was refused. A sandboxed app needs the "
        "com.apple.security.device.usb entitlement for camera controls");
  }
  IOUSBDeviceInterface** device = nullptr;
  (*plugin)->QueryInterface(plugin,
                            CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID),
                            reinterpret_cast<LPVOID*>(&device));
  (*plugin)->Release(plugin);
  if (device == nullptr) return fail("IOUSBDeviceInterface is unavailable");

  std::unique_ptr<UsbControlDevice> out(new UsbControlDevice());
  out->device_ = device;

  IOUSBConfigurationDescriptorPtr config = nullptr;
  if ((*device)->GetConfigurationDescriptorPtr(device, 0, &config) !=
          kIOReturnSuccess ||
      config == nullptr) {
    return fail("Failed to read the USB configuration descriptor");
  }
  const uint8_t* p = reinterpret_cast<const uint8_t*>(config);
  const size_t total = USBToHostWord(config->wTotalLength);
  bool in_vc = false;
  size_t offset = 0;
  while (offset + 2 <= total) {
    const uint8_t len = p[offset];
    const uint8_t type = p[offset + 1];
    if (len < 2 || offset + len > total) break;
    const uint8_t* d = p + offset;
    if (type == kDescriptorInterface && len >= 9) {
      in_vc = d[5] == kClassVideo && d[6] == kSubclassVideoControl;
      if (in_vc && out->interface_number_ < 0) out->interface_number_ = d[2];
    } else if (type == kDescriptorCsInterface && in_vc && len >= 3) {
      const uint8_t subtype = d[2];
      if (subtype == kVcInputTerminal && len >= 15 &&
          out->camera_terminal_id_ < 0) {
        const int terminal_type = d[4] | (d[5] << 8);
        const uint8_t size = d[14];
        if (terminal_type == kTerminalTypeCamera && 15 + size <= len) {
          out->camera_terminal_id_ = d[3];
          out->ct_controls_ = Bitmap(d + 15, size);
        }
      } else if (subtype == kVcProcessingUnit && len >= 8 &&
                 out->processing_unit_id_ < 0) {
        const uint8_t size = d[7];
        if (8 + size <= len) {
          out->processing_unit_id_ = d[3];
          out->pu_controls_ = Bitmap(d + 8, size);
        }
      }
    }
    offset += len;
  }
  if (out->interface_number_ < 0) {
    return fail("The USB device has no VideoControl interface");
  }
  return out;
}

UsbControlDevice::~UsbControlDevice() {
  if (device_ != nullptr) {
    IOUSBDeviceInterface** device =
        static_cast<IOUSBDeviceInterface**>(device_);
    (*device)->Release(device);
    device_ = nullptr;
  }
}

int UsbControlDevice::Request(bool is_ct, uint8_t selector, uint8_t request,
                              uint8_t* data, uint16_t length) {
  if (device_ == nullptr) return kErrorNoDevice;
  const int unit = is_ct ? camera_terminal_id_ : processing_unit_id_;
  if (unit < 0 || interface_number_ < 0) return kErrorNotSupported;

  IOUSBDeviceInterface** device = static_cast<IOUSBDeviceInterface**>(device_);
  IOUSBDevRequestTO r;
  memset(&r, 0, sizeof(r));
  r.bmRequestType = (request & 0x80) != 0 ? 0xA1 : 0x21;
  r.bRequest = request;
  r.wValue = static_cast<uint16_t>(selector << 8);
  r.wIndex = static_cast<uint16_t>((unit << 8) | interface_number_);
  r.wLength = length;
  r.pData = data;
  r.noDataTimeout = kRequestTimeoutMs;
  r.completionTimeout = kRequestTimeoutMs;
  const IOReturn kr = (*device)->DeviceRequestTO(device, &r);
  if (kr != kIOReturnSuccess) return MapReturn(kr);
  if ((request & 0x80) != 0 && r.wLenDone < length) return kErrorIo;
  return 0;
}

}  // namespace uvc_mac
