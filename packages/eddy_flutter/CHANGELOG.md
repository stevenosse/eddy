## 0.1.4

- Fix: a recomputed query kept hold of its dependencies only once it read them again; with a short `disposeDelay` they could be disposed in between, and a failed refresh lost the value it should keep.

## 0.1.3

- Fix: `watchOrNull` followed by `watch` on the same query failed with a cast error (the cache entry took the nullable type).

## 0.1.2

- `package:eddy_flutter/testing.dart` re-exports the testing helpers.

## 0.1.1

- `disposeDelay: Duration.zero` disposes unused queries in a microtask: no timer left pending in widget tests.
- README: start parallel watches then await them, instead of `(a, b).wait`.

## 0.1.0

- Initial release.
