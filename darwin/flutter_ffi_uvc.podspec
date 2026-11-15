#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint flutter_ffi_uvc.podspec` to validate before publishing.
#
pubspec = File.read(File.join(__dir__, '..', 'pubspec.yaml'))

Pod::Spec.new do |s|
  s.name             = 'flutter_ffi_uvc'
  s.version          = pubspec[/^version:\s*(\S+)/, 1]
  s.summary          = 'Control USB(UVC) cameras.'
  s.description      = <<-DESC
Control USB(UVC) cameras. Preview, capture, record, adjust settings, and read raw frames, for one camera or several.
                       DESC
  s.homepage         = 'https://github.com/cornpip/flutter_ffi_uvc'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'cornpip' => 'https://github.com/cornpip' }
  s.source           = { :path => '.' }

  # The sources include the shared request queue and C ABI header from
  # ../src by relative path, so only files under this directory are listed.
  s.source_files = 'flutter_ffi_uvc/Sources/flutter_ffi_uvc/**/*.{h,mm,cpp}'
  s.public_header_files = 'flutter_ffi_uvc/Sources/flutter_ffi_uvc/include/**/*.h'

  # One implementation, two platforms. IOKit, and with it the UVC controls,
  # exists on macOS only; on iPadOS uvc_usb_controls.cpp compiles to a stub.
  s.ios.deployment_target = '13.0'
  s.osx.deployment_target = '10.15'
  s.ios.dependency 'Flutter'
  s.osx.dependency 'FlutterMacOS'
  s.ios.frameworks = 'Accelerate', 'AVFoundation', 'CoreMedia', 'CoreVideo',
                     'ImageIO'
  s.osx.frameworks = 'Accelerate', 'AVFoundation', 'CoreMedia', 'CoreVideo',
                     'ImageIO', 'IOKit'

  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'CLANG_CXX_LANGUAGE_STANDARD' => 'c++17',
  }
  # Objective-C++ sources get no module autolinking, so the Flutter framework
  # is named here, once per platform.
  s.ios.pod_target_xcconfig = {
    'OTHER_LDFLAGS' => '$(inherited) -framework Flutter',
  }
  s.osx.pod_target_xcconfig = {
    'OTHER_LDFLAGS' => '$(inherited) -framework FlutterMacOS',
  }
end
