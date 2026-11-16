import 'dart:async';

import 'package:meta/meta.dart';

/// The state of an asynchronous value: loading, data or failure.
///
/// [AsyncLoading] and [AsyncFailure] may carry the previous value. A refresh
/// keeps showing what was there while it runs, and a failed refresh keeps the
/// data next to the error instead of wiping the screen.
@immutable
sealed class Async<T> {
  const Async._(this._value, this.hasValue);

  /// Loading, with no value to show.
  const factory Async.loading() = AsyncLoading<T>;

  /// A value is available.
  const factory Async.data(T value) = AsyncData<T>;

  /// Failed, with no value to show.
  const factory Async.failure(Object error, [StackTrace? stackTrace]) = AsyncFailure<T>;

  /// Runs [compute] and captures its outcome, including synchronous throws.
  static Future<Async<T>> guard<T>(FutureOr<T> Function() compute) async {
    try {
      return AsyncData(await compute());
    } catch (error, stackTrace) {
      return AsyncFailure(error, stackTrace);
    }
  }

  final T? _value;

  /// Whether a value is available, even while loading or after a failure.
  final bool hasValue;

  /// The value, or null if there is none.
  T? get valueOrNull => _value;

  /// The value. Throws a [StateError] when [hasValue] is false.
  T get value => hasValue ? _value as T : throw StateError('$runtimeType has no value');

  /// The error of an [AsyncFailure], otherwise null.
  Object? get errorOrNull => switch (this) {
    AsyncFailure(:final error) => error,
    _ => null,
  };

  /// The error when it is an [E], otherwise null.
  E? errorAs<E>() => switch (errorOrNull) {
    final E error => error,
    _ => null,
  };

  /// Loading, with or without a previous value.
  bool get isLoading => this is AsyncLoading<T>;

  /// Loading while a previous value is still shown.
  bool get isRefreshing => isLoading && hasValue;

  /// This state turned into loading, keeping the current value if any.
  AsyncLoading<T> toLoading() => hasValue ? AsyncLoading.withPrevious(_value as T) : AsyncLoading<T>();

  /// This state turned into a failure, keeping the current value if any.
  AsyncFailure<T> toFailure(Object error, [StackTrace? stackTrace]) =>
      hasValue ? AsyncFailure.withPrevious(error, _value as T, stackTrace) : AsyncFailure<T>(error, stackTrace);

  /// Transforms the value, keeping the state.
  Async<R> whenData<R>(R Function(T value) transform) => switch (this) {
    AsyncData(:final value) => AsyncData(transform(value)),
    AsyncLoading() when hasValue => AsyncLoading.withPrevious(transform(_value as T)),
    AsyncLoading() => AsyncLoading<R>(),
    AsyncFailure(:final error, :final stackTrace) when hasValue => AsyncFailure.withPrevious(
      error,
      transform(_value as T),
      stackTrace,
    ),
    AsyncFailure(:final error, :final stackTrace) => AsyncFailure<R>(error, stackTrace),
  };
}

/// Loading. [hasValue] is true when a previous value is kept during a refresh.
final class AsyncLoading<T> extends Async<T> {
  /// Loading with nothing to show.
  const AsyncLoading() : super._(null, false);

  /// Loading while [previous] is still shown.
  const AsyncLoading.withPrevious(T previous) : super._(previous, true);

  @override
  bool operator ==(Object other) => other is AsyncLoading<T> && other.hasValue == hasValue && other._value == _value;

  @override
  int get hashCode => Object.hash(AsyncLoading, hasValue, _value);

  @override
  String toString() => hasValue ? 'AsyncLoading<$T>(previous: $_value)' : 'AsyncLoading<$T>()';
}

/// A value is available.
final class AsyncData<T> extends Async<T> {
  /// Holds [value].
  const AsyncData(T value) : super._(value, true);

  @override
  T get value => _value as T;

  @override
  bool operator ==(Object other) => other is AsyncData<T> && other._value == _value;

  @override
  int get hashCode => Object.hash(AsyncData, _value);

  @override
  String toString() => 'AsyncData<$T>($_value)';
}

/// Failed. [hasValue] is true when the previous value is kept (failed refresh).
final class AsyncFailure<T> extends Async<T> {
  /// Failed with nothing to show.
  const AsyncFailure(this.error, [this.stackTrace]) : super._(null, false);

  /// Failed while [previous] is still shown.
  const AsyncFailure.withPrevious(this.error, T previous, [this.stackTrace]) : super._(previous, true);

  /// What went wrong.
  final Object error;

  /// Where it went wrong, when known.
  final StackTrace? stackTrace;

  @override
  bool operator ==(Object other) =>
      other is AsyncFailure<T> && other.error == error && other.hasValue == hasValue && other._value == _value;

  @override
  int get hashCode => Object.hash(AsyncFailure, error, hasValue, _value);

  @override
  String toString() => hasValue ? 'AsyncFailure<$T>($error, previous: $_value)' : 'AsyncFailure<$T>($error)';
}
