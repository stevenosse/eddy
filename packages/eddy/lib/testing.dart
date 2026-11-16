/// Helpers for testing flows and queries.
library;

import 'eddy.dart';

/// Records the states of a flow.
extension FlowRecording<S> on EddyFlow<S> {
  /// A list that receives every state emitted from now on.
  ///
  /// ```dart
  /// final states = flow.record();
  /// await flow.submit();
  /// expect(states, [isSubmitting, isDone]);
  /// ```
  List<S> record() {
    final states = <S>[];
    listen(states.add);
    return states;
  }
}

/// Records the states of a query.
extension QueryRecording on QueryClient {
  /// A list that receives the current state of [query], then every change.
  List<Async<T>> record<T>(Query<T> query) {
    final states = <Async<T>>[];
    listen(query, states.add);
    return states;
  }
}
