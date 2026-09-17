/// Speed policy plumbing (design doc §17). The scheduler holds the
/// policy; enforcement is delegated to the engine when
/// EngineCapabilities.speedLimit is true, otherwise to a throttle
/// layer in front of the adapter (Brisk has no limiter — the flag is
/// surfaced so callers/UI can show "not supported by this engine").
final class SpeedPolicy {
  const SpeedPolicy({this.globalBytesPerSecond});

  final int? globalBytesPerSecond;

  SpeedPolicy copyWith({int? globalBytesPerSecond, bool clearGlobal = false}) =>
      SpeedPolicy(
        globalBytesPerSecond:
            clearGlobal ? null : globalBytesPerSecond ?? this.globalBytesPerSecond,
      );
}
