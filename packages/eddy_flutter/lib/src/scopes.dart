import 'package:eddy/eddy.dart';
import 'package:flutter/widgets.dart';

/// Provides a [QueryClient] to the widgets below.
class QueryScope extends InheritedWidget {
  /// Provides [client]. The scope does not dispose it.
  const QueryScope({super.key, required this.client, required super.child});

  /// The client provided.
  final QueryClient client;

  /// The nearest client. Throws if there is none.
  static QueryClient of(BuildContext context) {
    final scope = context.getInheritedWidgetOfExactType<QueryScope>();
    assert(scope != null, 'No QueryScope above this widget');
    return scope!.client;
  }

  @override
  bool updateShouldNotify(QueryScope oldWidget) => client != oldWidget.client;
}

/// Creates a flow, provides it to the widgets below and closes it when removed.
class FlowScope<F extends EddyFlow<Object?>> extends StatefulWidget {
  /// Creates the flow once with [create].
  const FlowScope({super.key, required this.create, required this.child});

  /// Builds the flow, once.
  final F Function(BuildContext context) create;

  /// The widgets that can read the flow.
  final Widget child;

  /// The nearest flow of type [F]. Throws if there is none.
  static F of<F extends EddyFlow<Object?>>(BuildContext context) {
    final scope = context.getInheritedWidgetOfExactType<_FlowInherited<F>>();
    assert(scope != null, 'No FlowScope<$F> above this widget');
    return scope!.flow;
  }

  @override
  State<FlowScope<F>> createState() => _FlowScopeState<F>();
}

class _FlowScopeState<F extends EddyFlow<Object?>> extends State<FlowScope<F>> {
  late final F _flow = widget.create(context);

  @override
  void dispose() {
    _flow.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _FlowInherited<F>(flow: _flow, child: widget.child);
}

class _FlowInherited<F extends EddyFlow<Object?>> extends InheritedWidget {
  const _FlowInherited({required this.flow, required super.child});

  final F flow;

  @override
  bool updateShouldNotify(_FlowInherited<F> oldWidget) => flow != oldWidget.flow;
}
