import 'dart:async';

import 'package:eddy/eddy.dart';
import 'package:eddy/testing.dart';
import 'package:test/test.dart';

/// A fetcher whose calls are counted and whose results come from [values], in order.
class Source<T> {
  Source(this.values);

  final List<T> values;
  int calls = 0;

  T call(QueryRef q) => values[calls++ % values.length];
}

Future<void> settle(QueryClient client) async {
  await client.idle();
  await Future<void>.delayed(Duration.zero);
}

void main() {
  late QueryClient client;

  setUp(() => client = QueryClient(disposeDelay: Duration.zero));
  tearDown(() => client.dispose());

  group('reading', () {
    test('computes on first listen and shares the value', () async {
      final source = Source([1]);
      final query = Query(source.call);
      final a = client.record(query);
      final b = client.record(query);
      await settle(client);
      expect(a, [const AsyncLoading<int>(), const AsyncData(1)]);
      expect(b, [const AsyncLoading<int>(), const AsyncData(1)]);
      expect(source.calls, 1);
    });

    test('family members are equal by argument', () async {
      var calls = 0;
      final double = Query.family((int n, q) {
        calls++;
        return n * 2;
      });
      expect(double(2), double(2));
      expect(double(2), isNot(double(3)));
      expect(await client.fetch(double(2)), 4);
      client.listen(double(2), (_) {});
      expect(await client.fetch(double(3)), 6);
      expect(calls, 2);
    });

    test('a failure is a state, not a throw', () async {
      final query = Query<int>((q) => throw 'boom');
      final states = client.record(query);
      await settle(client);
      expect(states.last, isA<AsyncFailure<int>>().having((s) => s.error, 'error', 'boom'));
      await expectLater(client.fetch(query), throwsA('boom'));
    });

    test('dep resolves through the resolver', () async {
      final withDeps = QueryClient(resolve: <D extends Object>() => 'injected' as D);
      final query = Query((q) => q.dep<String>());
      expect(await withDeps.fetch(query), 'injected');
      await expectLater(client.fetch(query), throwsStateError);
    });
  });

  group('dependencies', () {
    test('a derived query is recomputed when its dependency is invalidated, keeping its value meanwhile', () async {
      final source = Source([1, 2]);
      final base = Query(source.call);
      final derived = Query((q) async => await q.watch(base) * 10);
      final states = client.record(derived);
      await settle(client);
      client.invalidate(base);
      await settle(client);
      expect(states, [
        const AsyncLoading<int>(),
        const AsyncData(10),
        const AsyncLoading.withPrevious(10),
        const AsyncData(20),
      ]);
    });

    test('depending on another key drops the previous value (another subject is loading)', () async {
      final selected = Query((q) => 'a');
      final detail = Query.family((String id, q) async => 'detail $id');
      final screen = Query((q) async => q.watch(detail(await q.watch(selected))));
      final states = client.record(screen);
      await settle(client);
      client.set(selected, 'b');
      await settle(client);
      expect(states, [
        const AsyncLoading<String>(),
        const AsyncData('detail a'),
        const AsyncLoading.withPrevious('detail a'),
        const AsyncLoading<String>(),
        const AsyncData('detail b'),
      ]);
    });

    test('an outdated computation is ignored', () async {
      final slow = Completer<String>();
      final selected = Query((q) => 'a');
      final detail = Query.family((String id, q) => id == 'a' ? slow.future : Future.value('b'));
      final screen = Query((q) async => q.watch(detail(await q.watch(selected))));
      final states = client.record(screen);
      await Future<void>.delayed(Duration.zero);
      client.set(selected, 'b');
      await settle(client);
      slow.complete('a');
      await settle(client);
      expect(states.last, const AsyncData('b'));
      expect(client.read(screen), const AsyncData('b'));
    });

    test('a failing dependency fails the caller, unless read with watchOrNull', () async {
      final failing = Query<int>((q) => throw 'boom');
      final strict = Query((q) => q.watch(failing));
      final lenient = Query((q) async => await q.watchOrNull(failing) ?? -1);
      await expectLater(client.fetch(strict), throwsA('boom'));
      expect(await client.fetch(lenient), -1);
    });

    test('diamond: every query reads the new values', () async {
      final source = Source([1, 2]);
      final root = Query(source.call);
      final middle = Query((q) async => await q.watch(root) + 100);
      final top = Query((q) async => '${await q.watch(root)}/${await q.watch(middle)}');
      final states = client.record(top);
      await settle(client);
      client.invalidate(root);
      await settle(client);
      expect(states.last, const AsyncData('2/102'));
      expect(source.calls, 2);
    });

    test('a query cannot watch itself', () async {
      late Query<int> self;
      self = Query((q) => q.watch(self));
      await expectLater(client.fetch(self), throwsStateError);
    });
  });

  group('refresh', () {
    test('recomputes the query and what it watches', () async {
      final leaf = Source([1, 2]);
      final base = Query(leaf.call);
      final derived = Query((q) async => await q.watch(base) * 10);
      client.listen(derived, (_) {});
      await settle(client);
      expect(await client.refresh(derived), const AsyncData(20));
      expect(leaf.calls, 2);
    });

    test('a failed refresh keeps the value next to the error', () async {
      var fail = false;
      final query = Query((q) => fail ? throw 'offline' : 1);
      client.listen(query, (_) {});
      await settle(client);
      fail = true;
      expect(await client.refresh(query), const AsyncFailure.withPrevious('offline', 1));
    });
  });

  group('invalidate', () {
    test('by tag, family or query', () async {
      final tagged = Source([1, 2]);
      final familySource = Source([1, 2]);
      final a = Query(tagged.call, tags: {'progress'});
      final b = Query.family((int n, q) => familySource(q) * n);
      client.listen(a, (_) {});
      client.listen(b(1), (_) {});
      await settle(client);

      client.invalidate('progress');
      client.invalidate(b);
      await settle(client);
      expect(client.read(a), const AsyncData(2));
      expect(client.read(b(1)), const AsyncData(2));

      client.invalidate(a);
      await settle(client);
      expect(tagged.calls, 3);
    });

    test('an unused cached query is dropped and computed again on next use', () async {
      final source = Source([1, 2]);
      final cached = Query(source.call, keepAlive: true);
      expect(await client.fetch(cached), 1);
      client.invalidate(cached);
      expect(source.calls, 1);
      expect(await client.fetch(cached), 2);
    });
  });

  group('set and update', () {
    test('replace the value and recompute dependents', () async {
      final base = Query((q) => [1]);
      final count = Query((q) async => (await q.watch(base)).length);
      final states = client.record(count);
      await settle(client);
      client.update(base, (list) => [...list, 2]);
      await settle(client);
      expect(client.read(base).value, [1, 2]);
      expect(states.last, const AsyncData(2));
    });

    test('setting an equal value recomputes nothing', () async {
      var computed = 0;
      final base = Query((q) => 'a');
      final derived = Query((q) async {
        computed++;
        return q.watch(base);
      });
      client.listen(derived, (_) {});
      await settle(client);
      client.set(base, 'a');
      await settle(client);
      expect(computed, 1);
    });

    test('set cancels a computation in flight', () async {
      final slow = Completer<int>();
      final query = Query((q) => slow.future);
      client.listen(query, (_) {});
      client.set(query, 2);
      slow.complete(1);
      await settle(client);
      expect(client.read(query), const AsyncData(2));
    });
  });

  group('disposal', () {
    test('a query nobody listens to is disposed', () async {
      final source = Source([1, 2]);
      final query = Query(source.call);
      final subscription = client.listen(query, (_) {});
      await settle(client);
      subscription.cancel();
      await settle(client);
      expect(client.read(query), const AsyncLoading<int>());
      expect(await client.fetch(query), 2);
    });

    test('keepAlive keeps the value', () async {
      final source = Source([1, 2]);
      final query = Query(source.call, keepAlive: true);
      client.listen(query, (_) {}).cancel();
      await settle(client);
      expect(client.read(query), const AsyncData(1));
    });

    test('a dependency lives as long as its dependents', () async {
      final source = Source([1, 2]);
      final base = Query(source.call);
      final derived = Query((q) => q.watch(base));
      final subscription = client.listen(derived, (_) {});
      await settle(client);
      expect(client.read(base), const AsyncData(1));
      subscription.cancel();
      await settle(client);
      await settle(client);
      expect(client.read(base), const AsyncLoading<int>());
    });

    test('a dependency no longer watched is released', () async {
      final selected = Query((q) => 'a');
      final detail = Query.family((String id, q) => id);
      final screen = Query((q) async => q.watch(detail(await q.watch(selected))));
      client.listen(screen, (_) {});
      await settle(client);
      client.set(selected, 'b');
      await settle(client);
      await settle(client);
      expect(client.read(detail('a')), const AsyncLoading<String>());
      expect(client.read(detail('b')), const AsyncData('b'));
    });
  });

  test('clear forgets everything and recomputes what is listened', () async {
    final user = Source(['alice', 'bob']);
    final me = Query(user.call, keepAlive: true);
    final greeting = Query((q) async => 'hi ${await q.watch(me)}');
    final other = Query((q) => 1, keepAlive: true);
    final states = client.record(greeting);
    await client.fetch(other);
    await settle(client);

    client.clear();
    await settle(client);
    expect(states.sublist(2), [const AsyncLoading<String>(), const AsyncData('hi bob')]);
    expect(client.read(other), const AsyncLoading<int>());
  });
}
