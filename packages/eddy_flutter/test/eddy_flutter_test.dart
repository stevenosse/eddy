import 'package:eddy_flutter/eddy_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class CounterState {
  const CounterState({this.count = 0, this.message});

  final int count;
  final String? message;

  @override
  bool operator ==(Object other) => other is CounterState && other.count == count && other.message == message;

  @override
  int get hashCode => Object.hash(count, message);
}

class CounterFlow extends EddyFlow<CounterState> {
  CounterFlow([super.initialState = const CounterState()]);

  bool closed = false;

  void increment() => emit(CounterState(count: state.count + 1, message: state.message));
  void say(String message) => emit(CounterState(count: state.count, message: message));

  @override
  void onClose() => closed = true;
}

Widget app(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  group('FlowView', () {
    testWidgets('rebuilds on new states and closes the flow it created', (tester) async {
      late CounterFlow flow;
      await tester.pumpWidget(
        app(
          FlowView<CounterFlow, CounterState>(
            create: (_) => flow = CounterFlow(),
            builder: (context, flow, state) => TextButton(onPressed: flow.increment, child: Text('${state.count}')),
          ),
        ),
      );
      expect(find.text('0'), findsOneWidget);
      await tester.tap(find.byType(TextButton));
      await tester.pump();
      expect(find.text('1'), findsOneWidget);

      await tester.pumpWidget(app(const SizedBox()));
      expect(flow.closed, isTrue);
    });

    testWidgets('reactions run once per change of the selected value, not on rebuilds', (tester) async {
      final flow = CounterFlow();
      final messages = <String?>[];
      await tester.pumpWidget(
        app(
          FlowScope<CounterFlow>(
            create: (_) => flow,
            child: FlowView<CounterFlow, CounterState>(
              reactions: [on((s) => s.message, (context, flow, message) => messages.add(message))],
              builder: (context, flow, state) => Text('${state.count}'),
            ),
          ),
        ),
      );
      flow.say('hello');
      await tester.pump();
      flow.increment();
      flow.increment();
      await tester.pump();
      flow.say('bye');
      await tester.pump();
      expect(messages, ['hello', 'bye']);
      expect(find.text('2'), findsOneWidget);
    });

    testWidgets('a reaction whose value changed before the view appeared runs after the first frame', (tester) async {
      final flow = CounterFlow()..say('early');
      final messages = <String?>[];
      await tester.pumpWidget(
        app(
          FlowScope<CounterFlow>(
            create: (_) => flow,
            child: FlowView<CounterFlow, CounterState>(
              reactions: [
                on((s) => s.message, (context, flow, message) => messages.add(message)),
                on((s) => s.count, (context, flow, count) => messages.add('count $count')),
              ],
              builder: (context, flow, state) => const SizedBox(),
            ),
          ),
        ),
      );
      expect(messages, ['early']);
    });

    testWidgets('a reaction can show a sheet', (tester) async {
      final flow = CounterFlow();
      await tester.pumpWidget(
        app(
          FlowView<CounterFlow, CounterState>(
            create: (_) => flow,
            reactions: [
              on((s) => s.message, (context, flow, message) {
                if (message != null) {
                  showModalBottomSheet<void>(context: context, builder: (_) => Text('sheet: $message'));
                }
              }),
            ],
            builder: (context, flow, state) => const SizedBox(),
          ),
        ),
      );
      flow.say('hi');
      await tester.pumpAndSettle();
      expect(find.text('sheet: hi'), findsOneWidget);
    });
  });

  group('AsyncView', () {
    Widget view(Async<int> value, {VoidCallback? onRetry, void Function(Object)? onRefreshError}) => app(
      AsyncViewDefaults(
        loading: (_) => const Text('loading'),
        error: (context, error, retry) => TextButton(onPressed: retry, child: Text('error $error')),
        onRefreshError: onRefreshError == null ? null : (context, error) => onRefreshError(error),
        child: AsyncView(value, onRetry: onRetry, builder: (context, v) => Text('value $v')),
      ),
    );

    testWidgets('renders loading, error with retry and values', (tester) async {
      var retried = 0;
      await tester.pumpWidget(view(const AsyncLoading()));
      expect(find.text('loading'), findsOneWidget);

      await tester.pumpWidget(view(const AsyncFailure('boom'), onRetry: () => retried++));
      await tester.tap(find.text('error boom'));
      expect(retried, 1);

      await tester.pumpWidget(view(const AsyncData(1)));
      expect(find.text('value 1'), findsOneWidget);
    });

    testWidgets('keeps the value while refreshing and reports a failed refresh once', (tester) async {
      final errors = <Object>[];
      await tester.pumpWidget(view(const AsyncData(1), onRefreshError: errors.add));
      await tester.pumpWidget(view(const AsyncLoading.withPrevious(1), onRefreshError: errors.add));
      expect(find.text('value 1'), findsOneWidget);

      await tester.pumpWidget(view(const AsyncFailure.withPrevious('offline', 1), onRefreshError: errors.add));
      await tester.pump();
      await tester.pumpWidget(view(const AsyncFailure.withPrevious('offline', 1), onRefreshError: errors.add));
      await tester.pump();
      expect(find.text('value 1'), findsOneWidget);
      expect(errors, ['offline']);
    });

    testWidgets('pull to refresh calls onRefresh', (tester) async {
      var refreshed = 0;
      await tester.pumpWidget(
        app(
          AsyncView(
            const AsyncData(1),
            onRefresh: () async => refreshed++,
            builder: (context, v) => ListView(children: const [SizedBox(height: 2000, child: Text('content'))]),
          ),
        ),
      );
      await tester.fling(find.byType(ListView), const Offset(0, 400), 1000);
      await tester.pumpAndSettle();
      expect(refreshed, 1);
    });
  });

  testWidgets('QueryScope and a QueryFlow end to end', (tester) async {
    final client = QueryClient(disposeDelay: Duration.zero);
    var n = 0;
    final counter = Query((q) async => ++n);
    await tester.pumpWidget(
      QueryScope(
        client: client,
        child: app(
          FlowView<QueryFlow<int>, Async<int>>(
            create: (context) => QueryFlow(counter, QueryScope.of(context)),
            builder: (context, flow, state) => AsyncView(
              state,
              builder: (context, value) => TextButton(onPressed: flow.refresh, child: Text('n=$value')),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('n=1'), findsOneWidget);
    await tester.tap(find.byType(TextButton));
    await tester.pumpAndSettle();
    expect(find.text('n=2'), findsOneWidget);

    client.invalidate(counter);
    await tester.pumpAndSettle();
    expect(find.text('n=3'), findsOneWidget);
    client.dispose();
  });
}
