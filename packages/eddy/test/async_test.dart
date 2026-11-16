import 'package:eddy/eddy.dart';
import 'package:test/test.dart';

void main() {
  test('values and flags', () {
    const loading = AsyncLoading<int>();
    expect(loading.hasValue, isFalse);
    expect(loading.isRefreshing, isFalse);
    expect(() => loading.value, throwsStateError);

    const refreshing = AsyncLoading.withPrevious(1);
    expect(refreshing.isRefreshing, isTrue);
    expect(refreshing.value, 1);

    const failed = AsyncFailure<int>.withPrevious('boom', 2);
    expect(failed.value, 2);
    expect(failed.errorOrNull, 'boom');
    expect(failed.errorAs<String>(), 'boom');
    expect(failed.errorAs<int>(), isNull);
  });

  test('nullable values are values', () {
    const data = AsyncData<int?>(null);
    expect(data.hasValue, isTrue);
    expect(data.toLoading(), const AsyncLoading<int?>.withPrevious(null));
  });

  test('toLoading and toFailure keep the value', () {
    expect(const AsyncData(1).toLoading(), const AsyncLoading.withPrevious(1));
    expect(const AsyncData(1).toFailure('x'), const AsyncFailure.withPrevious('x', 1));
    expect(const AsyncLoading<int>().toFailure('x'), const AsyncFailure<int>('x'));
  });

  test('equality', () {
    expect(const AsyncData(1), const AsyncData(1));
    expect(const AsyncData(1), isNot(const AsyncData(2)));
    expect(const AsyncLoading<int>(), isNot(const AsyncLoading.withPrevious(1)));
  });

  test('guard captures synchronous and asynchronous errors', () async {
    expect(await Async.guard(() => 1), const AsyncData(1));
    expect(
      await Async.guard<int>(() => throw 'sync'),
      isA<AsyncFailure<int>>().having((f) => f.error, 'error', 'sync'),
    );
    expect(await Async.guard<int>(() async => throw 'async'), isA<AsyncFailure<int>>());
  });

  test('whenData', () {
    expect(const AsyncData(2).whenData((v) => v * 2), const AsyncData(4));
    expect(const AsyncLoading.withPrevious(2).whenData((v) => '$v'), const AsyncLoading.withPrevious('2'));
    expect(const AsyncFailure<int>('x').whenData((v) => '$v'), const AsyncFailure<String>('x'));
  });
}
