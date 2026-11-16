# eddy

State management for Flutter in two pieces, with little boilerplate and no code generation:

- **Queries**: shared async data, declared once. They track what they depend on, cache their value, drop outdated results, and are recomputed when what they watch changes. Mutations invalidate them by tag or set them directly.
- **Flows**: one per screen. A flow holds an immutable state and exposes intents as methods (like a Cubit). Flows never talk to each other: they share data through queries.

The view only reacts: it rebuilds from the state, or runs a callback (show a sheet, navigate) when part of the state changes.

| Package | Contents |
| --- | --- |
| [`eddy`](packages/eddy) | Pure Dart: `Async`, `Query`, `QueryClient`, `EddyFlow`, `QueryFlow`, testing helpers |
| [`eddy_flutter`](packages/eddy_flutter) | `QueryScope`, `FlowScope`, `FlowView` with `on(...)` reactions, `AsyncView` |

## Async

`Async<T>` is `AsyncLoading`, `AsyncData` or `AsyncFailure`. Loading and failure can keep the previous value: a refresh keeps the screen filled, and a failed refresh keeps the data next to the error.

```dart
switch (state) {
  AsyncData(:final value) => ...,
  AsyncFailure(:final error) => ...,
  AsyncLoading() => ...,
}
```

## Queries

```dart
final todos = Query((q) => q.dep<TodoRepository>().all(), tags: {Tags.todos});
final todo = Query.family((String id, q) => q.dep<TodoRepository>().byId(id), keepAlive: true);

// Derived: q.watch returns the value and subscribes. If the dependency fails, so does this query.
final selectedTodo = Query((q) async => q.watch(todo(await q.watch(selectedId))));
final summary = Query((q) async {
  // Start both, then await: they load in parallel. Avoid `(a, b).wait`, which wraps errors in a
  // ParallelWaitError instead of failing with the dependency's own error.
  final stats = q.watchOrNull(statsQuery); // may fail without failing the summary
  final all = await q.watch(todos);
  return Summary(all, await stats);
});
```

A `QueryClient` holds the state of every query:

```dart
final queries = QueryClient(resolve: <T extends Object>() => locator<T>());

queries.listen(todos, (Async<List<Todo>> state) => ...);
await queries.fetch(todos);
await queries.refresh(summary);          // recomputes summary and everything it watches
queries.invalidate(Tags.todos);          // a tag, a query or a whole family
queries.set(todo('42'), saved);          // the mutation returned the new value
queries.update(todos, (list) => [...list, created]);
queries.clear();                         // logout
```

Rules worth knowing:

- A query is computed on first use and shared by every listener.
- It is recomputed when a query it watched is refreshed, invalidated or set. Every affected query is marked as running before any recomputation starts, so a diamond never reads stale values.
- **Refresh vs. reload.** While recomputing, the previous value is kept (`AsyncLoading.withPrevious`). If the new computation watches a query it did not watch before (another identifier, say), the previous value is about another subject and is dropped.
- A result that arrives after a newer computation started is ignored.
- A query nobody listens to, directly or through another query, is disposed after `disposeDelay` (30 s by default), unless it is `keepAlive`. With `Duration.zero` it is disposed in a microtask, so widget tests end with no pending timer.
- `invalidate` recomputes queries in use and drops unused cached ones.

## Flows

```dart
class TodoFlow extends EddyFlow<TodoState> {
  TodoFlow(this.id, this._repo, QueryClient queries) : super(const TodoState(), queries) {
    watch(todo(id), (value) => emit(state.copyWith(todo: value)));
  }

  final String id;
  final TodoRepository _repo;

  Future<void> refresh() => queries.refresh(todo(id));

  void edit(String title) {
    emit(state.copyWith(draft: title));
    debounce('save', const Duration(milliseconds: 600), _save);
  }

  Future<void> complete() => track(
        () async => queries.set(todo(id), await _repo.complete(id)),
        (progress) => state.copyWith(completing: progress),
      );

  Future<void> _save() async => queries.set(todo(id), await _repo.rename(id, state.draft));
}
```

- `emit` ignores equal states (use value equality, Freezed works well) and anything after `close`.
- `watch` mirrors a query, `track` turns an action into `Async` progress in the state, `every` and `debounce` run timers. All are cancelled by `close`.
- `QueryFlow<T>` is a ready-made flow whose state is a single query, with `refresh()`.

## Views

```dart
QueryScope(client: queries, child: AsyncViewDefaults(
  loading: (_) => const MyLoader(),
  error: (context, error, retry) => MyError(error, onRetry: retry),
  onRefreshError: (context, error) => showSnack(context, error),
  child: app,
));

FlowView<TodoFlow, TodoState>(
  create: (context) => TodoFlow(id, locator(), QueryScope.of(context)),
  reactions: [
    on((s) => s.completing, (context, flow, progress) => switch (progress) {
      AsyncData() => Navigator.of(context).pop(),
      AsyncFailure(:final error) => showErrorSheet(context, error),
      _ => null,
    }),
  ],
  builder: (context, flow, state) => AsyncView(
    state.todo,
    onRetry: flow.refresh,
    onRefresh: flow.refresh,
    builder: (context, todo) => TodoCard(todo, onComplete: flow.complete),
  ),
);
```

- A reaction runs when the value it selects changes, never on a rebuild, so a sheet opens once. If the value already differs from the flow's initial state when the view appears, it runs after the first frame.
- `create` scopes the flow to the view and closes it with the view. Without it, `FlowView` uses the nearest `FlowScope`.
- `AsyncView` shows the value whenever there is one, otherwise the loading or error widget, and reports a failed refresh once through `onRefreshError`.

## Testing

```dart
import 'package:eddy/testing.dart';

final queries = QueryClient(resolve: <T extends Object>() => fakes[T] as T);
final flow = TodoFlow('42', fakeRepo, queries);
final states = flow.record();
await flow.complete();
expect(states.map((s) => s.completing), [isA<AsyncLoading<void>>(), isA<AsyncData<void>>()]);

final values = queries.record(todos);
await queries.idle();
```

## License

MIT
