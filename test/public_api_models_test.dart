import 'package:flutter_ffi_uvc/flutter_ffi_uvc.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('public API model factories', () {
    test('UvcControlKind.fromUiType maps supported UI kinds', () {
      expect(UvcControlKind.fromUiType('bool'), UvcControlKind.boolean);
      expect(UvcControlKind.fromUiType('enum'), UvcControlKind.enumLike);
      expect(UvcControlKind.fromUiType('range'), UvcControlKind.integer);
    });

    test('UvcCameraMode.fromJson parses native mode metadata', () {
      final UvcCameraMode mode = UvcCameraMode.fromJson(<String, dynamic>{
        'format': 7,
        'formatName': 'MJPEG',
        'width': 1280,
        'height': 720,
        'fps': 30,
      });

      expect(mode.frameFormat, 7);
      expect(mode.formatName, 'MJPEG');
      expect(mode.width, 1280);
      expect(mode.height, 720);
      expect(mode.fps, 30);
      expect(mode.label, 'MJPEG 1280x720 @ 30fps');
      expect(mode.toJson(), <String, Object?>{
        'format': 7,
        'formatName': 'MJPEG',
        'width': 1280,
        'height': 720,
        'fps': 30,
      });
    });

    test('UvcCameraControl.fromJson keeps ID and UI metadata stable', () {
      final UvcCameraControl control =
          UvcCameraControl.fromJson(<String, dynamic>{
        'id': UvcControlId.focusAuto.nativeValue,
        'name': 'focus_auto',
        'label': 'Auto Focus',
        'uiType': 'bool',
        'min': 0,
        'max': 1,
        'def': 1,
        'cur': 0,
        'res': 1,
      });

      expect(control.id, UvcControlId.focusAuto);
      expect(control.name, 'focus_auto');
      expect(control.label, 'Auto Focus');
      expect(control.kind, UvcControlKind.boolean);
      expect(control.min, 0);
      expect(control.max, 1);
      expect(control.def, 1);
      expect(control.cur, 0);
      expect(control.res, 1);

      final UvcCameraControl updated = control.copyWithCur(1);
      expect(updated.cur, 1);
      expect(updated.id, control.id);
      expect(updated.label, control.label);
    });

    test('UvcBmControlInfo.fromJson preserves control descriptors', () {
      final UvcBmControlInfo control =
          UvcBmControlInfo.fromJson(<String, dynamic>{
        'id': UvcControlId.zoomAbs.nativeValue,
        'name': 'zoom_abs',
        'label': 'Zoom',
        'uiType': 'enum',
      });

      expect(control.id, UvcControlId.zoomAbs);
      expect(control.name, 'zoom_abs');
      expect(control.label, 'Zoom');
      expect(control.kind, UvcControlKind.enumLike);
    });

    test('compound control factories parse structured payloads', () {
      final UvcWhiteBalanceComponent whiteBalance =
          UvcWhiteBalanceComponent.fromJson(<String, dynamic>{
        'blue': 4100,
        'red': 3900,
      });
      final UvcFocusRelativeControl focus =
          UvcFocusRelativeControl.fromJson(<String, dynamic>{
        'focusRel': -1,
        'speed': 3,
      });
      final UvcZoomRelativeControl zoom =
          UvcZoomRelativeControl.fromJson(<String, dynamic>{
        'zoomRel': 1,
        'digitalZoom': 0,
        'speed': 2,
      });
      final UvcPanTiltAbsoluteControl panTiltAbs =
          UvcPanTiltAbsoluteControl.fromJson(<String, dynamic>{
        'pan': 120,
        'tilt': -45,
      });
      final UvcPanTiltRelativeControl panTiltRel =
          UvcPanTiltRelativeControl.fromJson(<String, dynamic>{
        'panRel': 1,
        'panSpeed': 4,
        'tiltRel': -1,
        'tiltSpeed': 5,
      });
      final UvcRollRelativeControl roll =
          UvcRollRelativeControl.fromJson(<String, dynamic>{
        'rollRel': 1,
        'speed': 6,
      });
      final UvcDigitalWindowControl digitalWindow =
          UvcDigitalWindowControl.fromJson(<String, dynamic>{
        'windowTop': 1,
        'windowLeft': 2,
        'windowBottom': 3,
        'windowRight': 4,
        'numSteps': 5,
        'numStepsUnits': 6,
      });
      final UvcRegionOfInterestControl regionOfInterest =
          UvcRegionOfInterestControl.fromJson(<String, dynamic>{
        'roiTop': 10,
        'roiLeft': 20,
        'roiBottom': 30,
        'roiRight': 40,
        'autoControls': 50,
      });

      expect(whiteBalance.blue, 4100);
      expect(whiteBalance.red, 3900);
      expect(focus.focusRel, -1);
      expect(focus.speed, 3);
      expect(zoom.zoomRel, 1);
      expect(zoom.digitalZoom, 0);
      expect(zoom.speed, 2);
      expect(panTiltAbs.pan, 120);
      expect(panTiltAbs.tilt, -45);
      expect(panTiltRel.panRel, 1);
      expect(panTiltRel.panSpeed, 4);
      expect(panTiltRel.tiltRel, -1);
      expect(panTiltRel.tiltSpeed, 5);
      expect(roll.rollRel, 1);
      expect(roll.speed, 6);
      expect(digitalWindow.windowTop, 1);
      expect(digitalWindow.windowLeft, 2);
      expect(digitalWindow.windowBottom, 3);
      expect(digitalWindow.windowRight, 4);
      expect(digitalWindow.numSteps, 5);
      expect(digitalWindow.numStepsUnits, 6);
      expect(regionOfInterest.roiTop, 10);
      expect(regionOfInterest.roiLeft, 20);
      expect(regionOfInterest.roiBottom, 30);
      expect(regionOfInterest.roiRight, 40);
      expect(regionOfInterest.autoControls, 50);
    });
  });
}
