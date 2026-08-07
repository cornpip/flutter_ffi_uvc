# Frame access: why there is no push-based frame stream

A `Stream<UvcPreviewFrame>` API (native code pushing frames into Dart) was
considered and rejected. Frame access in Dart is pull-only: call
`copyLatestFrame()` when you are ready to process a frame.

## Pulled frames are fresher

Frame consumers — ML inference, analysis, custom encoding — usually run
slower than the camera, and what they want is the *newest* frame at the
moment they are ready, not every frame in order.

- **Pull:** finish your work, then grab the latest frame. It is as fresh as
  it can be.
- **Push:** a frame is copied into Dart and waits in the event queue until
  your previous work finishes. By the time it is processed it is stale, and
  a newer frame already exists on the native side.

## Push needs a queue the pipeline doesn't have

The native pipeline never queues: when a frame arrives while the previous
one is still being processed, it is dropped, and the preview always shows
the latest frame. A push stream that promises every frame would need
queueing — and once the consumer is slower than the camera, that queue only
grows until frames get dropped anyway.

## Push copies whether you need it or not

Every pushed frame is a full RGBA copy across the native → Dart boundary
(~8 MB per 1080p frame), used or not. Pull pays that cost only for frames
you actually ask for.

## Recommended pattern

To process frames at a fixed rate, poll on a timer:

```dart
final timer = Timer.periodic(const Duration(milliseconds: 100), (_) {
  final frame = uvcCamera.copyLatestFrame();
  if (frame != null) {
    // process frame — always the newest one available right now
  }
});
```
