import 'sourin_api.dart';

/// Share recovery work between the home shelf and library page. Call only after
/// existing records have rendered; slow metadata requests never hold up the list.
abstract final class LibraryCoverRecovery {
  static final _coordinator = CoverRepairCoordinator(
    SourinApi.repairLibraryCovers,
  );

  static Future<int> repair() => _coordinator.repair();
}

/// Coalesces callers without holding up initial library rendering.
class CoverRepairCoordinator {
  CoverRepairCoordinator(this._repair, {DateTime Function()? now})
    : _now = now ?? DateTime.now;

  final Future<int> Function() _repair;
  final DateTime Function() _now;
  Future<int>? _pending;
  DateTime? _lastAttempt;
  static const _cooldown = Duration(minutes: 1);

  Future<int> repair() {
    final pending = _pending;
    if (pending != null) return pending;
    final now = _now();
    if (_lastAttempt != null && now.difference(_lastAttempt!) < _cooldown) {
      return Future.value(0);
    }
    _lastAttempt = now;
    return _pending = _run();
  }

  Future<int> _run() async {
    try {
      return await Future<int>.sync(_repair);
    } catch (_) {
      return 0;
    } finally {
      _pending = null;
    }
  }
}
