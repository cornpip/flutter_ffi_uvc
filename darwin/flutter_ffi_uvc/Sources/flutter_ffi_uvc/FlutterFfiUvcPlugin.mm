#import "include/flutter_ffi_uvc/FlutterFfiUvcPlugin.h"

#import <AVFoundation/AVFoundation.h>

#include <atomic>
#include <cstdint>

#include "../../../../src/include/flutter_ffi_uvc.h"
#import "uvc_avf_backend.h"

namespace {

// Pins the session with a registry id for the scope so uvc_session_destroy
// waits until the ABI calls made here have returned. Holds nothing when the
// id is not a live session.
class SessionPin {
 public:
  explicit SessionPin(int64_t id)
      : session_(id > 0 ? uvc_session_acquire_id(static_cast<uint64_t>(id))
                        : nullptr) {}
  ~SessionPin() {
    if (session_ != nullptr) uvc_session_release(session_);
  }
  SessionPin(const SessionPin&) = delete;
  SessionPin& operator=(const SessionPin&) = delete;
  uvc_session_t* get() const { return session_; }

 private:
  uvc_session_t* session_;
};

int64_t Int64FromArgs(id args, NSString* key, int64_t fallback) {
  if (![args isKindOfClass:[NSDictionary class]]) return fallback;
  id value = ((NSDictionary*)args)[key];
  if (![value isKindOfClass:[NSNumber class]]) return fallback;
  return ((NSNumber*)value).longLongValue;
}

NSString* StringFromUtf8(const std::string& value) {
  return [NSString stringWithUTF8String:value.c_str()] ?: @"";
}

NSDictionary* DeviceToMap(const uvc_mac::DeviceInfo& info) {
  const BOOL authorized =
      [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo] ==
      AVAuthorizationStatusAuthorized;
  return @{
    @"deviceId" : @(info.device_id),
    @"deviceName" : StringFromUtf8(info.unique_id),
    @"vendorId" : @(info.vendor_id),
    @"productId" : @(info.product_id),
    @"productName" : StringFromUtf8(info.name),
    @"manufacturerName" : StringFromUtf8(info.manufacturer),
    @"serialNumber" : @"",
    @"hasPermission" : @(authorized),
  };
}

// Completes on the main thread with whether the app may use cameras, asking
// the user when that has not been decided yet.
void EnsureCameraAccess(void (^completion)(BOOL granted)) {
  const AVAuthorizationStatus status =
      [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo];
  if (status != AVAuthorizationStatusNotDetermined) {
    completion(status == AVAuthorizationStatusAuthorized);
    return;
  }
  [AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo
                           completionHandler:^(BOOL granted) {
                             dispatch_async(dispatch_get_main_queue(), ^{
                               completion(granted);
                             });
                           }];
}

}  // namespace

// One registered Flutter texture. A texture is bound to at most one session
// and a session to at most one texture. The session's frame listener carries
// this object as its user_data, unretained: detaching clears the listener
// before the plugin lets go of the texture.
@interface UvcPreviewTexture : NSObject <FlutterTexture>
@property(nonatomic, assign) int64_t textureId;
@property(nonatomic, weak) id<FlutterTextureRegistry> registry;
// Registry id of the bound session, 0 when unbound. Read on the raster
// thread by copyPixelBuffer, written on the platform thread.
- (int64_t)sessionId;
- (int64_t)exchangeSessionId:(int64_t)sessionId;
- (void)frameAvailable;
@end

@implementation UvcPreviewTexture {
  std::atomic<int64_t> _session;
}

- (instancetype)init {
  self = [super init];
  if (self != nil) {
    _session.store(0);
  }
  return self;
}

- (int64_t)sessionId {
  return _session.load();
}

- (int64_t)exchangeSessionId:(int64_t)sessionId {
  return _session.exchange(sessionId);
}

- (CVPixelBufferRef)copyPixelBuffer {
  // Raster thread. The texture can be detached and its session destroyed
  // while this runs. The pin keeps the session alive until the copy is done.
  SessionPin pin(_session.load());
  if (pin.get() == nullptr) return nullptr;
  return uvc_mac::CopyPreviewPixelBuffer(pin.get());
}

- (void)frameAvailable {
  // Called on the capture queue. The registry is only used on the main
  // thread.
  const int64_t textureId = self.textureId;
  __weak id<FlutterTextureRegistry> registry = self.registry;
  dispatch_async(dispatch_get_main_queue(), ^{
    [registry textureFrameAvailable:textureId];
  });
}

@end

namespace {

void OnNativeFrameAvailable(void* context, int64_t /*sequence*/) {
  // The texture outlives this call: clearing the listener returns only
  // after it has finished.
  UvcPreviewTexture* texture = (__bridge UvcPreviewTexture*)context;
  [texture frameAvailable];
}

// Unbinds a texture from its session and clears the frame listener.
void DetachTexture(UvcPreviewTexture* texture) {
  // The Dart side may already have destroyed the session. The pin then fails
  // and there is no listener left to clear.
  SessionPin pin([texture exchangeSessionId:0]);
  if (pin.get() != nullptr) {
    uvc_set_frame_listener(pin.get(), nullptr, nullptr);
  }
}

}  // namespace

@interface FlutterFfiUvcPlugin () <FlutterStreamHandler>
@end

@implementation FlutterFfiUvcPlugin {
  __weak id<FlutterTextureRegistry> _textures;
  NSMutableDictionary<NSNumber*, UvcPreviewTexture*>* _previewTextures;
  FlutterEventSink _deviceEventSink;
  id _connectObserver;
  id _disconnectObserver;
  // Connection notifications are only posted while something has asked
  // AVFoundation for devices.
  AVCaptureDeviceDiscoverySession* _discovery;
}

+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar>*)registrar {
  FlutterFfiUvcPlugin* plugin =
      [[FlutterFfiUvcPlugin alloc] initWithTextures:registrar.textures];

  FlutterMethodChannel* textureChannel =
      [FlutterMethodChannel methodChannelWithName:@"flutter_ffi_uvc/texture"
                                  binaryMessenger:registrar.messenger];
  [textureChannel
      setMethodCallHandler:^(FlutterMethodCall* call, FlutterResult result) {
        [plugin handleTextureCall:call result:result];
      }];

  FlutterMethodChannel* usbChannel =
      [FlutterMethodChannel methodChannelWithName:@"flutter_ffi_uvc/usb"
                                  binaryMessenger:registrar.messenger];
  [usbChannel
      setMethodCallHandler:^(FlutterMethodCall* call, FlutterResult result) {
        [plugin handleUsbCall:call result:result];
      }];

  FlutterEventChannel* deviceEvents =
      [FlutterEventChannel eventChannelWithName:@"flutter_ffi_uvc/device_events"
                                binaryMessenger:registrar.messenger];
  [deviceEvents setStreamHandler:plugin];
}

- (instancetype)initWithTextures:(id<FlutterTextureRegistry>)textures {
  self = [super init];
  if (self != nil) {
    _textures = textures;
    _previewTextures = [NSMutableDictionary dictionary];
  }
  return self;
}

- (void)dealloc {
  [self stopDeviceNotifications];
  for (UvcPreviewTexture* texture in _previewTextures.allValues) {
    DetachTexture(texture);
    [_textures unregisterTexture:texture.textureId];
  }
}

// FlutterPlugin registers the plugin for method calls on channels that name
// it as their delegate. The channels above use blocks instead.
- (void)handleMethodCall:(FlutterMethodCall*)call result:(FlutterResult)result {
  result(FlutterMethodNotImplemented);
}

- (void)handleTextureCall:(FlutterMethodCall*)call
                   result:(FlutterResult)result {
  if ([call.method isEqualToString:@"createPreviewTexture"]) {
    id<FlutterTextureRegistry> textures = _textures;
    UvcPreviewTexture* texture = [[UvcPreviewTexture alloc] init];
    texture.registry = textures;
    const int64_t textureId = [textures registerTexture:texture];
    if (textures == nil || textureId < 0) {
      result([FlutterError errorWithCode:@"texture_create_failed"
                                 message:@"registerTexture failed"
                                 details:nil]);
      return;
    }
    texture.textureId = textureId;
    _previewTextures[@(textureId)] = texture;
    result(@(textureId));
    return;
  }

  if ([call.method isEqualToString:@"disposePreviewTexture"]) {
    const int64_t textureId = Int64FromArgs(call.arguments, @"textureId", -1);
    UvcPreviewTexture* texture = _previewTextures[@(textureId)];
    if (texture != nil) {
      [_previewTextures removeObjectForKey:@(textureId)];
      DetachTexture(texture);
      // The engine keeps the texture object alive while the raster thread
      // may still be inside copyPixelBuffer.
      [_textures unregisterTexture:textureId];
    }
    result(nil);
    return;
  }

  if ([call.method isEqualToString:@"attachPreviewTexture"]) {
    const int64_t textureId = Int64FromArgs(call.arguments, @"textureId", -1);
    UvcPreviewTexture* texture = _previewTextures[@(textureId)];
    if (texture == nil) {
      result([FlutterError errorWithCode:@"texture_not_found"
                                 message:@"Unknown textureId"
                                 details:nil]);
      return;
    }
    const int64_t sessionId =
        Int64FromArgs(call.arguments, @"sessionHandle", 0);
    SessionPin pin(sessionId);
    if (pin.get() == nullptr) {
      result([FlutterError
          errorWithCode:@"invalid_session"
                message:@"sessionHandle is missing or not a live session"
                details:nil]);
      return;
    }
    // A session drives at most one texture. Unbind it from any other texture
    // and unbind this texture from any other session.
    for (UvcPreviewTexture* other in _previewTextures.allValues) {
      if (other != texture && [other sessionId] == sessionId) {
        [other exchangeSessionId:0];
      }
    }
    if ([texture sessionId] != sessionId) DetachTexture(texture);
    [texture exchangeSessionId:sessionId];
    uvc_set_frame_listener(pin.get(), &OnNativeFrameAvailable,
                           (__bridge void*)texture);
    result(nil);
    return;
  }

  result(FlutterMethodNotImplemented);
}

- (void)handleUsbCall:(FlutterMethodCall*)call result:(FlutterResult)result {
  if ([call.method isEqualToString:@"ensureCameraPermission"]) {
    EnsureCameraAccess(^(BOOL granted) {
      result(@(granted));
    });
    return;
  }

  if ([call.method isEqualToString:@"listUsbDevices"]) {
    NSMutableArray* devices = [NSMutableArray array];
    for (const uvc_mac::DeviceInfo& info : uvc_mac::ListDevices()) {
      [devices addObject:DeviceToMap(info)];
    }
    result(devices);
    return;
  }

  if ([call.method isEqualToString:@"openUsbDevice"]) {
    const int64_t sessionId =
        Int64FromArgs(call.arguments, @"sessionHandle", 0);
    const int64_t requestId = Int64FromArgs(call.arguments, @"requestId", 0);
    const int64_t deviceId = Int64FromArgs(call.arguments, @"deviceId", -1);
    if (sessionId <= 0 || requestId <= 0) {
      result([FlutterError
          errorWithCode:@"invalid_args"
                message:@"sessionHandle and requestId are required."
                details:nil]);
      return;
    }
    if (deviceId < 0 || deviceId > INT32_MAX ||
        !uvc_mac::DeviceExists(static_cast<int>(deviceId))) {
      result([FlutterError
          errorWithCode:@"device_not_found"
                message:[NSString
                            stringWithFormat:@"No UVC device with id %lld",
                                             deviceId]
                details:nil]);
      return;
    }
    // There is no fd on macOS. The device id goes to the queued open, where
    // uvc_open_fd interprets it. Nothing to release afterwards, so the
    // plugin registers no platform listener. A refused permission still
    // supplies the id: the open then fails with UVC_ERROR_ACCESS.
    EnsureCameraAccess(^(BOOL granted) {
      SessionPin pin(sessionId);
      if (pin.get() != nullptr) {
        uvc_supply_fd(pin.get(), requestId, static_cast<int>(deviceId));
      }
      result(nil);
    });
    return;
  }

  result(FlutterMethodNotImplemented);
}

#pragma mark - Device events

- (FlutterError*)onListenWithArguments:(id)arguments
                             eventSink:(FlutterEventSink)events {
  _deviceEventSink = events;
  [self startDeviceNotifications];
  return nil;
}

- (FlutterError*)onCancelWithArguments:(id)arguments {
  [self stopDeviceNotifications];
  _deviceEventSink = nil;
  return nil;
}

- (void)startDeviceNotifications {
  if (_connectObserver != nil) return;
  _discovery = uvc_mac::CreateDiscoverySession();

  __weak FlutterFfiUvcPlugin* weakSelf = self;
  NSNotificationCenter* center = NSNotificationCenter.defaultCenter;
  _connectObserver =
      [center addObserverForName:AVCaptureDeviceWasConnectedNotification
                          object:nil
                           queue:NSOperationQueue.mainQueue
                      usingBlock:^(NSNotification* note) {
                        [weakSelf onDevice:note.object attached:YES];
                      }];
  _disconnectObserver =
      [center addObserverForName:AVCaptureDeviceWasDisconnectedNotification
                          object:nil
                           queue:NSOperationQueue.mainQueue
                      usingBlock:^(NSNotification* note) {
                        [weakSelf onDevice:note.object attached:NO];
                      }];
}

- (void)stopDeviceNotifications {
  NSNotificationCenter* center = NSNotificationCenter.defaultCenter;
  if (_connectObserver != nil) {
    [center removeObserver:_connectObserver];
    _connectObserver = nil;
  }
  if (_disconnectObserver != nil) {
    [center removeObserver:_disconnectObserver];
    _disconnectObserver = nil;
  }
  _discovery = nil;
}

- (void)onDevice:(id)object attached:(BOOL)attached {
  if (_deviceEventSink == nil) return;
  if (![object isKindOfClass:[AVCaptureDevice class]]) return;
  AVCaptureDevice* device = (AVCaptureDevice*)object;
  if (!uvc_mac::IsListedDevice(device)) return;
  _deviceEventSink(@{
    @"event" : attached ? @"attached" : @"detached",
    @"device" : DeviceToMap(uvc_mac::InfoForDevice(device)),
  });
}

@end
