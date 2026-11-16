import 'package:eddy/eddy.dart';

final counter = Query((q) async => 1, tags: {'counter'});
final doubled = Query((q) async => await q.watch(counter) * 2);

class DoubledFlow extends QueryFlow<int> {
  DoubledFlow(QueryClient queries) : super(doubled, queries);
}

// ignore_for_file: avoid_print

Future<void> main() async {
  final queries = QueryClient();
  final flow = DoubledFlow(queries)..listen((state) => print('doubled: $state'));
  await queries.idle();
  queries.set(counter, 21);
  await queries.idle();
  flow.close();
  queries.dispose();
}
