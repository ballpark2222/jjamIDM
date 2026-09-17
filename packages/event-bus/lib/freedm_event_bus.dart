/// FreeDM event bus (design doc §24). Generic over event objects —
/// deliberately has no dependency on core-domain so any package can
/// publish through it.
library;

import 'dart:async';

/// Port: publish/subscribe hub between domain, application, UI.
abstract interface class EventBus {
  void publish(Object event);

  /// All events of type [T].
  Stream<T> on<T extends Object>();

  Future<void> close();
}

/// In-process implementation. One broadcast controller per type is
/// created lazily; events published before a subscriber attaches are
/// not replayed (history lives in persistence, not the bus).
final class InMemoryEventBus implements EventBus {
  final _controllers = <Type, StreamController<Object>>{};

  @override
  void publish(Object event) {
    _controllers[event.runtimeType]?.add(event);
  }

  @override
  Stream<T> on<T extends Object>() {
    final c = _controllers.putIfAbsent(
      T,
      () => StreamController<Object>.broadcast(),
    );
    return c.stream.where((e) => e is T).cast<T>();
  }

  @override
  Future<void> close() async {
    for (final c in _controllers.values) {
      await c.close();
    }
    _controllers.clear();
  }
}
