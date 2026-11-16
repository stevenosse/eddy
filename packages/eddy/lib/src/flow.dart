import 'dart:async';

import 'package:meta/meta.dart';

import 'async.dart';
import 'query.dart';
import 'query_client.dart';

/// Holds the state of a screen and exposes its intents as methods.
///
/// A flow emits immutable states; the view rebuilds from them or reacts to their
/// transitions. Flows never talk to each other: they share data through queries.
///
/// ```dart
/// class CounterFlow extends EddyFlow<int> {
///   CounterFlow() : super(0);
///   void increment() => emit(state + 1);
/// }
/// ```
///
/// Everything started through [watch], [every] and [debounce] is cancelled by [close].
abstract class EddyFlow<S> {
  /// Starts in [initialState]. Pass [queries] to use [watch] and [this.queries].
  EddyFlow(this.initialState, [QueryClient? queries]) : _state = initialState, _queries = queries;

  /// The state the flow started in.
  final S initialState;

  final QueryClient? _queries;
  S _state;
  bool _closed = false;
  final List<void Function(S)> _listeners = [];
  final List<QuerySubscription> _subscriptions = [];
  final List<Timer> _timers = [];
  final Map<Object, Timer> _debounces = {};

  /// The current state.
  S get state => _state;

  /// Whether [close] was called.
  bool get isClosed => _closed;

  /// The query client given to the constructor.
  @protected
  QueryClient get queries =>
      _queries ?? (throw StateError('$runtimeType has no QueryClient: pass one to the EddyFlow constructor'));

  /// Calls [listener] on every new state. Returns a function that stops listening.
  void Function() listen(void Function(S state) listener) {
    _listeners.add(listener);
    return () => _listeners.remove(listener);
  }

  /// Replaces the state. Ignored after [close] or when [next] equals the current state.
  @protected
  void emit(S next) {
    if (_closed || next == _state) return;
    _state = next;
    for (final listener in [..._listeners]) {
      try {
        listener(next);
      } catch (error, stackTrace) {
        Zone.current.handleUncaughtError(error, stackTrace);
      }
    }
  }

  /// Calls [onChange] with the state of [query] now and on every change, until [close].
  @protected
  void watch<T>(Query<T> query, void Function(Async<T> value) onChange) {
    _subscriptions.add(
      queries.listen(query, (value) {
        if (!_closed) onChange(value);
      }),
    );
  }

  /// Runs [action] and emits [reduce] of its progress: [AsyncLoading], then [AsyncData]
  /// or [AsyncFailure]. [reduce] is called with the state at that moment.
  ///
  /// ```dart
  /// Future<void> save() => track(() => repo.save(state.draft), (s) => state.copyWith(saving: s));
  /// ```
  @protected
  Future<Async<T>> track<T>(FutureOr<T> Function() action, S Function(Async<T> progress) reduce) async {
    emit(reduce(AsyncLoading<T>()));
    final result = await Async.guard(action);
    emit(reduce(result));
    return result;
  }

  /// Calls [action] every [period] until [close].
  @protected
  void every(Duration period, void Function() action) {
    _timers.add(
      Timer.periodic(period, (_) {
        if (!_closed) action();
      }),
    );
  }

  /// Calls [action] once [delay] has passed without another call for the same [key].
  @protected
  void debounce(Object key, Duration delay, void Function() action) {
    _debounces[key]?.cancel();
    _debounces[key] = Timer(delay, () {
      _debounces.remove(key);
      if (!_closed) action();
    });
  }

  /// Cancels a pending [debounce] for [key].
  @protected
  void cancelDebounce(Object key) => _debounces.remove(key)?.cancel();

  /// Called once by [close], for extra cleanup.
  @protected
  void onClose() {}

  /// Stops the flow: listeners, query subscriptions and timers are released.
  @mustCallSuper
  void close() {
    if (_closed) return;
    _closed = true;
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    for (final timer in [..._timers, ..._debounces.values]) {
      timer.cancel();
    }
    _subscriptions.clear();
    _timers.clear();
    _debounces.clear();
    _listeners.clear();
    onClose();
  }
}

/// A flow whose state is a single query, for screens that only show it.
///
/// ```dart
/// class TodosFlow extends QueryFlow<List<Todo>> {
///   TodosFlow(QueryClient queries) : super(todos, queries);
/// }
/// ```
class QueryFlow<T> extends EddyFlow<Async<T>> {
  /// Mirrors [query].
  QueryFlow(this.query, QueryClient queries) : super(AsyncLoading<T>(), queries) {
    watch(query, emit);
  }

  /// The query shown.
  final Query<T> query;

  /// Recomputes the query and what it depends on. Also used to retry after a failure.
  Future<void> refresh() => queries.refresh(query);
}
