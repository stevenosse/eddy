import 'package:eddy/eddy.dart';
import 'package:flutter/widgets.dart';

import 'scopes.dart';

/// Reacts to a change of the value [select] picks from the state, see [on].
abstract class Reaction<F, S> {
  const Reaction._();

  bool _changed(S previous, S next);

  void _fire(BuildContext context, F flow, S state);
}

class _SelectedReaction<F, S, T> extends Reaction<F, S> {
  const _SelectedReaction(this._select, this._react) : super._();

  final T Function(S state) _select;
  final void Function(BuildContext context, F flow, T value) _react;

  @override
  bool _changed(S previous, S next) => _select(previous) != _select(next);

  @override
  void _fire(BuildContext context, F flow, S state) => _react(context, flow, _select(state));
}

/// A reaction for [FlowView.reactions]: calls [react] when the value [select] picks from the
/// state changes. Not on rebuilds, so a sheet or a navigation runs once per change.
///
/// ```dart
/// on((s) => s.launched, (context, flow, session) => context.router.push(QuizRoute(session: session)))
/// ```
///
/// If the value already differs from the flow's initial state when the view appears, [react]
/// runs after the first frame.
Reaction<F, S> on<F, S, T>(T Function(S state) select, void Function(BuildContext context, F flow, T value) react) =>
    _SelectedReaction<F, S, T>(select, react);

/// Rebuilds from a flow's state and runs [reactions] on its transitions.
///
/// The flow comes from [create] or, without it, from the nearest [FlowScope].
class FlowView<F extends EddyFlow<S>, S> extends StatelessWidget {
  /// Shows a flow.
  const FlowView({super.key, this.create, this.reactions = const [], required this.builder});

  /// Creates the flow and scopes it to this view. Without it, the flow comes from a [FlowScope].
  final F Function(BuildContext context)? create;

  /// Callbacks run when part of the state changes, see [on].
  final List<Reaction<F, S>> reactions;

  /// Builds the view from the state. Pass the flow's methods down as callbacks.
  final Widget Function(BuildContext context, F flow, S state) builder;

  @override
  Widget build(BuildContext context) {
    final body = _FlowViewBody<F, S>(reactions: reactions, builder: builder);
    final create = this.create;
    return create == null ? body : FlowScope<F>(create: create, child: body);
  }
}

class _FlowViewBody<F extends EddyFlow<S>, S> extends StatefulWidget {
  const _FlowViewBody({required this.reactions, required this.builder});

  final List<Reaction<F, S>> reactions;
  final Widget Function(BuildContext context, F flow, S state) builder;

  @override
  State<_FlowViewBody<F, S>> createState() => _FlowViewBodyState<F, S>();
}

class _FlowViewBodyState<F extends EddyFlow<S>, S> extends State<_FlowViewBody<F, S>> {
  F? _flow;
  void Function()? _stopListening;
  late S _state;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final flow = FlowScope.of<F>(context);
    if (identical(flow, _flow)) return;
    _stopListening?.call();
    _flow = flow;
    _state = flow.state;
    _stopListening = flow.listen(_onState);
    final initial = flow.initialState;
    final pending = widget.reactions.where((r) => r._changed(initial, _state)).toList();
    if (pending.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !identical(_flow, flow)) return;
        for (final reaction in pending) {
          reaction._fire(context, flow, _state);
        }
      });
    }
  }

  void _onState(S next) {
    final previous = _state;
    _state = next;
    if (!mounted) return;
    setState(() {});
    for (final reaction in widget.reactions) {
      if (reaction._changed(previous, next)) reaction._fire(context, _flow as F, next);
    }
  }

  @override
  void dispose() {
    _stopListening?.call();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _flow as F, _state);
}
