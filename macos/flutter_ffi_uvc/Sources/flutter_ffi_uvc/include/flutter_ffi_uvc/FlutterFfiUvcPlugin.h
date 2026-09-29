#import <FlutterMacOS/FlutterMacOS.h>

// macOS counterpart of the Android and Windows plugins: implements the
// flutter_ffi_uvc/texture and flutter_ffi_uvc/usb method channels and the
// flutter_ffi_uvc/device_events event channel over the AVFoundation backend
// linked into the same binary.
@interface FlutterFfiUvcPlugin : NSObject <FlutterPlugin>
@end
