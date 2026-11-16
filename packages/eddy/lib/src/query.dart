import 'dart:async';

import 'package:meta/meta.dart';

import 'query_client.dart';

/// Computes the value of a query. Use [QueryRef.watch] to depend on other queries.
typedef Fetcher<T> = FutureOr<T> Function(QueryRef q);

/// A piece of shared asynchronous data, declared once and read through a [QueryClient].
///
/// ```dart
/// final todos = Query((q) => q.dep<TodoRepository>().all(), tags: {'todos'});
/// final doneCount = Query((q) async => (await q.watch(todos)).where((t) => t.done).length);
/// ```
///
/// A query is a key: the client holds its state, caches it, tracks which other
/// queries it watched and recomputes it when they change.
@immutable
class Query<T> {
  /// A query computed by [fetch].
  ///
  /// [keepAlive] keeps the value cached after the last listener leaves.
  /// [tags] group queries for [QueryClient.invalidate].
  Query(Fetcher<T> fetch, {this.keepAlive = false, this.tags = const {}, this.debugLabel})
    : _fetch = fetch,
      origin = null,
      arg = null;

  Query._member(QueryFamily<T, Object?> this.origin, this.arg, Fetcher<T> fetch)
    : _fetch = fetch,
      keepAlive = origin.keepAlive,
      tags = origin.tags,
      debugLabel = origin.debugLabel == null ? null : '${origin.debugLabel}($arg)';

  /// A query per argument, such as one per identifier.
  ///
  /// ```dart
  /// final todo = Query.family((String id, q) => q.dep<TodoRepository>().byId(id));
  /// q.watch(todo('42'));
  /// ```
  static QueryFamily<T, A> family<T, A>(
    FutureOr<T> Function(A arg, QueryRef q) fetch, {
    bool keepAlive = false,
    Set<Object> tags = const {},
    String? debugLabel,
  }) => QueryFamily(fetch, keepAlive: keepAlive, tags: tags, debugLabel: debugLabel);

  final Fetcher<T> _fetch;

  /// Whether the value stays cached when nothing listens to it anymore.
  final bool keepAlive;

  /// Groups this query belongs to, for [QueryClient.invalidate].
  final Set<Object> tags;

  /// Name shown in [toString].
  final String? debugLabel;

  /// The family this query was created from, if any.
  final QueryFamily<T, Object?>? origin;

  /// The argument this query was created with, when it belongs to a family ([origin]).
  final Object? arg;

  /// Runs the fetcher. Used by [QueryClient].
  @internal
  FutureOr<T> run(QueryRef q) => _fetch(q);

  /// Calls [f] with this query's own value type, whatever static type the caller sees it with
  /// (a `Query<int>` read as a `Query<int?>` still gives `int`). Used by [QueryClient].
  @internal
  R withValueType<R>(R Function<X>(Query<X> query) f) => f<T>(this);

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    final origin = this.origin;
    return origin != null && other is Query<T> && identical(other.origin, origin) && other.arg == arg;
  }

  @override
  int get hashCode => origin == null ? identityHashCode(this) : Object.hash(identityHashCode(origin), arg);

  @override
  String toString() => 'Query<$T>(${debugLabel ?? (origin == null ? identityHashCode(this) : arg)})';
}

/// Creates one [Query] per argument. Two calls with equal arguments give the same query.
///
/// The family itself can be passed to [QueryClient.invalidate] to target all its members.
class QueryFamily<T, A> {
  /// See [Query.family].
  QueryFamily(this._fetch, {this.keepAlive = false, this.tags = const {}, this.debugLabel});

  final FutureOr<T> Function(A arg, QueryRef q) _fetch;

  /// Whether members stay cached when nothing listens to them anymore.
  final bool keepAlive;

  /// Groups the members belong to.
  final Set<Object> tags;

  /// Name shown in members' [Query.toString].
  final String? debugLabel;

  /// The member for [arg].
  Query<T> call(A arg) => Query._member(this, arg, (q) => _fetch(arg, q));

  @override
  String toString() => 'QueryFamily<$T, $A>(${debugLabel ?? identityHashCode(this)})';
}
