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
  s.dependency 'FlutterMacOS'
  s.frameworks = 'Accelerate', 'AVFoundation', 'CoreMedia', 'CoreVideo', 'ImageIO', 'IOKit'

  s.platform = :osx, '10.15'
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'CLANG_CXX_LANGUAGE_STANDARD' => 'c++17',
    # Objective-C++ sources get no module autolinking, so the Flutter
    # framework is named here.
    'OTHER_LDFLAGS' => '$(inherited) -framework FlutterMacOS',
  }
end
