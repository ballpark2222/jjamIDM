import 'package:freedm_event_bus/freedm_event_bus.dart';
import 'package:test/test.dart';

class A {
  A(this.v);
  final int v;
}

class B {
  B(this.v);
  final int v;
}

void main() {
  test('typed streams only see their own type', () async {
    final bus = InMemoryEventBus();
    final seen = <int>[];
    final sub = bus.on<A>().listen((e) => seen.add(e.v));
    bus.publish(A(1));
    bus.publish(B(9));
    bus.publish(A(2));
    await Future<void>.delayed(Duration.zero);
    expect(seen, [1, 2]);
    await sub.cancel();
    await bus.close();
  });
}
