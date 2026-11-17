import 'dart:async';

import 'package:media_kit/media_kit.dart';

/// Keeps asynchronous native disposal alive until the desktop engine can close.
/// Normal route disposal also stays registered until its Future completes.
class PlayerDisposalRegistry {
  final _players = <Object, _Disposal>{};
  Future<void>? _shutdown;

  bool get isClosing => _shutdown != null;

  void register(Object owner, Future<void> Function() release) {
    if (isClosing) throw StateError('Player creation during shutdown');
    if (_players.containsKey(owner)) {
      throw StateError('Player is already registered');
    }
    _players[owner] = _Disposal(release);
  }

  Future<void> dispose(Object owner) {
    final entry = _players[owner];
    if (entry == null) return Future<void>.value();
    final pending = entry.pending;
    if (pending != null) return pending;
    final completion = Completer<void>();
    entry.pending = completion.future;
    Future<void>.sync(entry.release).then((_) {
      _players.remove(owner);
      completion.complete();
    }, onError: completion.completeError);
    return completion.future;
  }

  Future<void> shutdown() {
    final pending = _shutdown;
    if (pending != null) return pending;
    final completion = Completer<void>();
    _shutdown = completion.future;
    Future.wait<void>([
      for (final owner in _players.keys.toList()) dispose(owner),
    ]).then(completion.complete, onError: completion.completeError);
    return completion.future;
  }
}

class _Disposal {
  _Disposal(this.release);
  final Future<void> Function() release;
  Future<void>? pending;
}

/// Production players all share the same terminal engine-lifetime boundary.
class AppPlayer extends Player {
  factory AppPlayer({
    PlayerConfiguration configuration = const PlayerConfiguration(),
    FutureOr<void> Function()? beforeDispose,
  }) {
    if (lifecycle.isClosing) {
      throw StateError('Player creation during shutdown');
    }
    return AppPlayer._(configuration, beforeDispose);
  }

  AppPlayer._(
    PlayerConfiguration configuration,
    FutureOr<void> Function()? beforeDispose,
  ) : super(configuration: configuration) {
    lifecycle.register(this, () async {
      await beforeDispose?.call();
      await super.dispose();
    });
  }

  static final lifecycle = PlayerDisposalRegistry();

  @override
  Future<void> dispose() => lifecycle.dispose(this);
}
