import 'package:eddy/eddy.dart';
import 'package:eddy/testing.dart';
import 'package:fake_async/fake_async.dart';
import 'package:test/test.dart';

class CounterFlow extends EddyFlow<int> {
  CounterFlow([QueryClient? queries]) : super(0, queries);

  int ticks = 0;
  int saves = 0;
  bool cleaned = false;

  void set(int value) => emit(value);
  void startTicking() => every(const Duration(seconds: 1), () => ticks++);
  void typed() => debounce('save', const Duration(milliseconds: 500), () => saves++);
  void cancelSave() => cancelDebounce('save');
  Future<Async<int>> load(Future<int> Function() action) => track(action, (progress) => progress.valueOrNull ?? -1);
  void mirror(Query<int> query) => watch(query, (value) => emit(value.valueOrNull ?? -1));

  @override
  void onClose() => cleaned = true;
}

void main() {
  test('emit notifies listeners, skips equal states and stops after close', () {
    final flow = CounterFlow();
    final states = flow.record();
    flow
      ..set(1)
      ..set(1)
      ..set(2)
      ..close()
      ..set(3);
    expect(states, [1, 2]);
    expect(flow.state, 2);
    expect(flow.isClosed, isTrue);
    expect(flow.cleaned, isTrue);
    expect(flow.initialState, 0);
  });

  test('track emits loading then the outcome', () async {
    final flow = CounterFlow();
    final states = flow.record();
    expect(await flow.load(() async => 5), const AsyncData(5));
    final failure = await flow.load(() async => throw 'boom');
    expect(failure.errorOrNull, 'boom');
    expect(states, [-1, 5, -1]);
  });

  test('watch mirrors a query until close, which releases it', () async {
    final client = QueryClient(disposeDelay: Duration.zero);
    final query = Query((q) => 7);
    final flow = CounterFlow(client)..mirror(query);
    await client.idle();
    expect(flow.state, 7);
    client.set(query, 8);
    expect(flow.state, 8);
    flow.close();
    await Future<void>.delayed(Duration.zero);
    expect(client.read(query), const AsyncLoading<int>());
  });

  test('queries without a client is an error', () {
    expect(() => CounterFlow().mirror(Query((q) => 1)), throwsStateError);
  });

  test('every and debounce run until close', () {
    fakeAsync((time) {
      final flow = CounterFlow()..startTicking();
      time.elapse(const Duration(seconds: 3));
      expect(flow.ticks, 3);

      flow.typed();
      time.elapse(const Duration(milliseconds: 300));
      flow.typed();
      time.elapse(const Duration(milliseconds: 300));
      expect(flow.saves, 0);
      time.elapse(const Duration(milliseconds: 300));
      expect(flow.saves, 1);

      flow
        ..typed()
        ..cancelSave();
      time.elapse(const Duration(seconds: 1));
      expect(flow.saves, 1);

      flow
        ..typed()
        ..close();
      time.elapse(const Duration(seconds: 5));
      expect(flow.ticks, 4);
      expect(flow.saves, 1);
    });
  });

  test('QueryFlow mirrors its query and refreshes it', () async {
    final client = QueryClient();
    var n = 0;
    final query = Query((q) => ++n);
    final flow = QueryFlow(query, client);
    await client.idle();
    expect(flow.state, const AsyncData(1));
    await flow.refresh();
    expect(flow.state, const AsyncData(2));
  });
}
