import 'dart:async';

import 'async.dart';
import 'query.dart';

/// Resolves a dependency for [QueryRef.dep], for instance `locator.call` with get_it.
typedef DependencyResolver = D Function<D extends Object>();

/// A subscription to a query, returned by [QueryClient.listen].
abstract interface class QuerySubscription {
  /// Stops listening. The query may then be disposed.
  void cancel();
}

/// Handed to a [Fetcher]: reads other queries and dependencies.
abstract interface class QueryRef {
  /// The value of [query]. The calling query is recomputed whenever [query] is refreshed,
  /// invalidated or set. If [query] fails, its error is thrown here and fails the caller too.
  Future<T> watch<T>(Query<T> query);

  /// Like [watch], but a failure of [query] gives null instead of failing the caller.
  Future<T?> watchOrNull<T>(Query<T> query);

  /// A dependency from the client's resolver.
  D dep<D extends Object>();

  /// False once this computation is outdated: a newer one started or the query was disposed.
  /// Its result will be ignored.
  bool get isActive;
}

/// Holds the state of every [Query]: caching, dependency tracking, invalidation and disposal.
///
/// Queries are computed on first use and recomputed when something they watched changes.
/// A query nobody listens to (directly or through another query) is disposed after
/// [disposeDelay], unless it is [Query.keepAlive].
class QueryClient {
  /// Creates a client. [resolve] provides dependencies to [QueryRef.dep].
  QueryClient({this._resolve, this.disposeDelay = const Duration(seconds: 30)});

  final DependencyResolver? _resolve;

  /// How long an unused query stays cached before being disposed. With [Duration.zero], it is
  /// disposed in a microtask, which leaves no timer pending (handy in widget tests).
  final Duration disposeDelay;

  final Map<Query<Object?>, _Entry<Object?>> _entries = {};
  int _running = 0;
  Completer<void>? _idle;

  /// The current state of [query], without starting it.
  Async<T> read<T>(Query<T> query) => (_entries[query] as _Entry<T>?)?.state ?? AsyncLoading<T>();

  /// Listens to [query], computing it if needed. [onChange] is called right away with the
  /// current state unless [fireImmediately] is false, then on every change.
  QuerySubscription listen<T>(Query<T> query, void Function(Async<T>) onChange, {bool fireImmediately = true}) {
    final entry = _entryFor(query);
    final listener = _Listener<T>(onChange);
    entry.listeners.add(listener);
    entry.cancelDisposal();
    _start(entry);
    if (fireImmediately) listener.notify(entry.state);
    return _Subscription(() {
      entry.listeners.remove(listener);
      _scheduleDisposal(entry);
    });
  }

  /// The value of [query], computing it if needed. Throws if it fails.
  Future<T> fetch<T>(Query<T> query) {
    final entry = _entryFor(query);
    _start(entry);
    final result = entry.future;
    result.whenComplete(() => _scheduleDisposal(entry)).ignore();
    return result;
  }

  /// Recomputes [query] and everything it watches, transitively: what a pull-to-refresh expects.
  /// The previous value is kept while it runs, and kept next to the error if it fails.
  Future<Async<T>> refresh<T>(Query<T> query) async {
    final entry = _entryFor(query);
    if (!entry.started) {
      _start(entry);
    } else {
      final affected = <_Entry<Object?>>{};
      _collectDependencies(entry, affected);
      _rerun(affected);
    }
    try {
      await entry.future;
    } catch (_) {
      // The state carries the error.
    }
    _scheduleDisposal(entry);
    return entry.state;
  }

  /// Marks data as outdated. [target] is a [Query], a [QueryFamily] (all its members) or a tag.
  ///
  /// Queries in use are recomputed, along with the queries that watch them. Unused cached
  /// queries are dropped and computed again on next use.
  void invalidate(Object target) {
    final matching = _entries.values.where((e) => _matches(e.query, target)).toList();
    final rerun = <_Entry<Object?>>{};
    for (final entry in matching) {
      if (entry.isUsed) {
        rerun.add(entry);
      } else {
        _remove(entry);
      }
    }
    _rerun(rerun);
  }

  /// Replaces the value of [query], for instance with the result of a mutation.
  /// Queries watching it are recomputed. Does nothing if the query already holds an equal value.
  void set<T>(Query<T> query, T value) {
    final entry = _entryFor(query);
    if (!entry.isRunning && entry.state == AsyncData<T>(value)) return;
    entry.started = true;
    entry.complete(value);
    _rerun(_dependentsOf(entry));
    _scheduleDisposal(entry);
  }

  /// Transforms the current value of [query]. Does nothing if it has no value yet.
  void update<T>(Query<T> query, T Function(T value) transform) {
    final state = read(query);
    if (state.hasValue) set(query, transform(state.value));
  }

  /// Forgets everything, for instance on logout. Queries with listeners are computed again.
  void clear() {
    final listened = _entries.values.where((e) => e.listeners.isNotEmpty).toSet();
    for (final entry in _entries.values.toList()) {
      if (!listened.contains(entry)) _remove(entry);
    }
    for (final entry in listened) {
      entry.reset();
    }
    _rerun(listened);
  }

  /// Completes when no query is being computed.
  Future<void> idle() {
    if (_running == 0) return Future.value();
    return (_idle ??= Completer<void>()).future;
  }

  /// Disposes every query. The client must not be used afterwards.
  void dispose() {
    for (final entry in _entries.values.toList()) {
      _remove(entry);
    }
  }

  // The entry gets the query's own value type: a caller may see it with a wider one.
  _Entry<T> _entryFor<T>(Query<T> query) =>
      (_entries[query] ??= query.withValueType(<X>(q) => _Entry<X>(q, this))) as _Entry<T>;

  void _start(_Entry<Object?> entry) {
    if (entry.started) return;
    entry.started = true;
    entry.markRunning();
    _fetch(entry);
  }

  /// Recomputes [entries] and, transitively, the queries watching them.
  /// All are marked running before any computation starts, so a query reading another
  /// affected query waits for its new value instead of reading the old one.
  void _rerun(Set<_Entry<Object?>> entries) {
    if (entries.isEmpty) return;
    final affected = <_Entry<Object?>>{};
    void addWithDependents(_Entry<Object?> entry) {
      if (!affected.add(entry)) return;
      entry.dependents.forEach(addWithDependents);
    }

    entries.forEach(addWithDependents);
    for (final entry in affected) {
      entry.started = true;
      entry.markRunning();
    }
    affected.forEach(_fetch);
  }

  void _fetch(_Entry<Object?> entry) {
    final generation = entry.generation;
    final previousDependencies = entry.dependencies;
    // The previous dependencies stay held until the computation settles: it is about to read most
    // of them again, and releasing them now could dispose them in between.
    entry.heldDependencies.addAll(previousDependencies);
    entry.dependencies = {};
    unawaited(
      entry.runAndSettle(_Ref(this, entry, generation, previousDependencies)).whenComplete(() => _releaseHeld(entry)),
    );
  }

  /// Once the latest computation settled, lets go of the dependencies it did not read again.
  void _releaseHeld(_Entry<Object?> entry) {
    if (entry.isRunning || entry.removed) return;
    for (final dependency in entry.heldDependencies.difference(entry.dependencies)) {
      dependency.dependents.remove(entry);
      _scheduleDisposal(dependency);
    }
    entry.heldDependencies.clear();
  }

  void _runningChanged(int delta) {
    _running += delta;
    if (_running == 0) {
      _idle?.complete();
      _idle = null;
    }
  }

  void _collectDependencies(_Entry<Object?> entry, Set<_Entry<Object?>> into) {
    if (!into.add(entry)) return;
    for (final dependency in entry.dependencies) {
      _collectDependencies(dependency, into);
    }
  }

  Set<_Entry<Object?>> _dependentsOf(_Entry<Object?> entry) => {...entry.dependents};

  bool _matches(Query<Object?> query, Object target) {
    if (target is Query) return query == target;
    if (target is QueryFamily) return identical(query.origin, target);
    return query.tags.contains(target);
  }

  void _scheduleDisposal(_Entry<Object?> entry) {
    if (entry.isUsed || entry.query.keepAlive || entry.removed) return;
    void disposeIfUnused() {
      if (!entry.isUsed && !entry.query.keepAlive) _remove(entry);
    }

    // Without delay, a microtask: no timer left pending (widget tests check that).
    if (disposeDelay == Duration.zero) return scheduleMicrotask(disposeIfUnused);
    entry.disposalTimer ??= Timer(disposeDelay, () {
      entry.disposalTimer = null;
      disposeIfUnused();
    });
  }

  void _remove(_Entry<Object?> entry) {
    if (entry.removed) return;
    if (identical(_entries[entry.query], entry)) _entries.remove(entry.query);
    entry.dispose();
    for (final dependency in {...entry.dependencies, ...entry.heldDependencies}) {
      dependency.dependents.remove(entry);
      _scheduleDisposal(dependency);
    }
    entry.dependencies = {};
    entry.heldDependencies.clear();
  }
}

class _Entry<T> {
  _Entry(this.query, this.client);

  final Query<T> query;
  final QueryClient client;
  Async<T> state = AsyncLoading<T>();
  final List<_Listener<T>> listeners = [];
  final Set<_Entry<Object?>> dependents = {};
  Set<_Entry<Object?>> dependencies = {};

  /// Dependencies of an earlier computation, kept until the current one settles.
  final Set<_Entry<Object?>> heldDependencies = {};
  int generation = 0;
  bool started = false;
  bool removed = false;
  Completer<T>? _pending;
  Timer? disposalTimer;

  bool get isUsed => listeners.isNotEmpty || dependents.isNotEmpty;
  bool get isRunning => _pending != null;

  /// The value once the current computation settles.
  Future<T> get future {
    final pending = _pending;
    if (pending != null) return pending.future;
    return switch (state) {
      AsyncData(:final value) => Future.value(value),
      AsyncFailure(:final error, :final stackTrace) => Future.error(error, stackTrace),
      // Not started: callers start the entry before reading its future.
      AsyncLoading() => throw StateError('$query has not been started'),
    };
  }

  void markRunning() {
    generation++;
    if (_pending == null) {
      final pending = Completer<T>();
      pending.future.ignore();
      _pending = pending;
      client._runningChanged(1);
    }
    _setState(state.toLoading());
  }

  /// The computation now depends on something it did not before: the previous value is
  /// about another subject (another identifier), so it should not be shown while loading.
  void dropPrevious() {
    if (state case AsyncLoading(hasValue: true)) _setState(AsyncLoading<T>());
  }

  Future<void> runAndSettle(_Ref ref) async {
    final generation = this.generation;
    try {
      final value = await query.run(ref);
      if (generation == this.generation && !removed) complete(value);
    } catch (error, stackTrace) {
      if (generation == this.generation && !removed) fail(error, stackTrace);
    }
  }

  void complete(T value) {
    generation++; // A computation still running is now outdated.
    _setState(AsyncData(value));
    final pending = _pending;
    _pending = null;
    pending?.complete(value);
    if (pending != null) client._runningChanged(-1);
  }

  void fail(Object error, StackTrace stackTrace) {
    _setState(state.toFailure(error, stackTrace));
    final pending = _pending;
    _pending = null;
    pending?.completeError(error, stackTrace);
    if (pending != null) client._runningChanged(-1);
  }

  void reset() => _setState(AsyncLoading<T>());

  void cancelDisposal() {
    disposalTimer?.cancel();
    disposalTimer = null;
  }

  void dispose() {
    removed = true;
    generation++;
    cancelDisposal();
    final pending = _pending;
    _pending = null;
    pending?.completeError(StateError('$query was disposed'));
    if (pending != null) client._runningChanged(-1);
    listeners.clear();
  }

  void _setState(Async<T> next) {
    if (next == state) return;
    state = next;
    for (final listener in [...listeners]) {
      listener.notify(next);
    }
  }
}

class _Listener<T> {
  _Listener(this.onChange);

  final void Function(Async<T>) onChange;

  void notify(Async<T> state) {
    try {
      onChange(state);
    } catch (error, stackTrace) {
      Zone.current.handleUncaughtError(error, stackTrace);
    }
  }
}

class _Subscription implements QuerySubscription {
  _Subscription(this._onCancel);

  void Function()? _onCancel;

  @override
  void cancel() {
    _onCancel?.call();
    _onCancel = null;
  }
}

class _Ref implements QueryRef {
  _Ref(this._client, this._entry, this._generation, this._previousDependencies);

  final QueryClient _client;
  final _Entry<Object?> _entry;
  final int _generation;
  final Set<_Entry<Object?>> _previousDependencies;

  @override
  bool get isActive => _generation == _entry.generation && !_entry.removed;

  @override
  Future<T> watch<T>(Query<T> query) {
    if (query == _entry.query) throw StateError('$query cannot watch itself');
    final dependency = _client._entryFor(query);
    if (isActive) {
      _entry.dependencies.add(dependency);
      dependency.dependents.add(_entry);
      dependency.cancelDisposal();
      if (!_previousDependencies.contains(dependency)) _entry.dropPrevious();
    }
    _client._start(dependency);
    return dependency.future;
  }

  @override
  Future<T?> watchOrNull<T>(Query<T> query) async {
    try {
      return await watch<T>(query);
    } catch (_) {
      return null;
    }
  }

  @override
  D dep<D extends Object>() {
    final resolve = _client._resolve;
    if (resolve == null) throw StateError('QueryClient has no resolver: pass `resolve` to use q.dep()');
    return resolve<D>();
  }
}
