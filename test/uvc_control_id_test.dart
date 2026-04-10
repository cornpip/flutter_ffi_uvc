import 'package:flutter_ffi_uvc/flutter_ffi_uvc.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('UvcControlId', () {
    test('maps known native values to stable static instances', () {
      expect(
        UvcControlId.fromNativeValue(UvcControlId.brightness.nativeValue),
        same(UvcControlId.brightness),
      );
      expect(
        UvcControlId.fromNativeValue(UvcControlId.focusAuto.nativeValue),
        same(UvcControlId.focusAuto),
      );
      expect(
        UvcControlId.fromNativeValue(UvcControlId.zoomAbs.nativeValue),
        same(UvcControlId.zoomAbs),
      );
    });

    test('keeps unknown native values round-trippable', () {
      const int unknownValue = 987654321;

      final UvcControlId unknown = UvcControlId.fromNativeValue(unknownValue);

      expect(unknown.nativeValue, unknownValue);
      expect(unknown.debugName, 'unknown($unknownValue)');
      expect(unknown, UvcControlId.fromNativeValue(unknownValue));
      expect(unknown, isNot(UvcControlId.brightness));
    });
  });
}
