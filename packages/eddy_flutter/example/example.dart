import 'package:eddy_flutter/eddy_flutter.dart';
import 'package:flutter/material.dart';

var _count = 0;
final counter = Query((q) async => ++_count);

class CounterFlow extends QueryFlow<int> {
  CounterFlow(QueryClient queries) : super(counter, queries);
}

void main() => runApp(
  QueryScope(
    client: QueryClient(),
    child: const MaterialApp(home: CounterScreen()),
  ),
);

class CounterScreen extends StatelessWidget {
  const CounterScreen({super.key});

  @override
  Widget build(BuildContext context) => FlowView<CounterFlow, Async<int>>(
    create: (context) => CounterFlow(QueryScope.of(context)),
    reactions: [
      on((s) => s.valueOrNull, (context, flow, value) {
        if (value != null) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Fetched $value')));
      }),
    ],
    builder: (context, flow, state) => Scaffold(
      body: AsyncView(
        state,
        onRetry: flow.refresh,
        onRefresh: flow.refresh,
        builder: (context, value) => ListView(children: [ListTile(title: Text('Fetched $value times'))]),
      ),
    ),
  );
}
