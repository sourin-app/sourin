import 'dart:async';

/// Reads native cache properties while playback is active.
///
/// A cycle owns one generation and reads properties serially. Pausing invalidates
/// its result; a slow native read never starts overlapping polling cycles.
class PlayerBufferPoller {
  PlayerBufferPoller({
    required this.read,
    required this.onChanged,
    this.interval = const Duration(milliseconds: 500),
  });

  /// The native adapter returns null for unavailable properties.
  final Future<double?> Function(String key) read;
  final void Function(Duration? end, double? statePercent, double? span)
  onChanged;
  final Duration interval;

  Timer? _timer;
  bool _reading = false;
  int _generation = 0;
  bool _hasSample = false;
  (int?, double?, double?)? _last;

  bool get running => _timer != null;

  void start() {
    if (running) return;
    _hasSample = false;
    _timer = Timer.periodic(interval, (_) => unawaited(_tick()));
  }

  void stop() {
    _generation++;
    _timer?.cancel();
    _timer = null;
  }

  void clear() => stop();

  bool _current(int generation) => running && generation == _generation;

  static double? _finite(double? value) =>
      value != null && value.isFinite ? value : null;

  // Cache durations must also survive conversion from seconds to milliseconds.
  static double? _seconds(double? value) =>
      value != null && value >= 0 && (value * 1000).isFinite ? value : null;

  Future<void> _tick() async {
    if (!running || _reading) return;
    final generation = _generation;
    _reading = true;
    try {
      final end = _seconds(await read('demuxer-cache-time'));
      if (!_current(generation)) return;
      final percent = _finite(await read('cache-buffering-state'));
      if (!_current(generation)) return;
      final span = _seconds(await read('demuxer-cache-duration'));
      if (!_current(generation)) return;
      final ms = end == null ? null : (end * 1000).round();
      final sample = (ms, percent, span);
      if (_hasSample && sample == _last) return;
      _last = sample;
      _hasSample = true;
      onChanged(ms == null ? null : Duration(milliseconds: ms), percent, span);
    } finally {
      _reading = false;
    }
  }
}
