import 'package:eddy/eddy.dart';
import 'package:flutter/material.dart';

/// Builds the error shown by [AsyncView] when there is no value. [retry] may be null.
typedef AsyncErrorBuilder = Widget Function(BuildContext context, Object error, VoidCallback? retry);

/// How [AsyncView]s below render loading and errors, and report failed refreshes.
/// Install it once near the root with the app's own widgets and messages.
class AsyncViewDefaults extends InheritedWidget {
  /// Defaults for the [AsyncView]s below.
  const AsyncViewDefaults({
    super.key,
    this.loading = _loading,
    this.error = _error,
    this.onRefreshError,
    required super.child,
  });

  /// Shown while loading with nothing to show.
  final WidgetBuilder loading;

  /// Shown on failure with nothing to show.
  final AsyncErrorBuilder error;

  /// Called when a refresh fails while the previous value stays on screen,
  /// for instance to show a snackbar.
  final void Function(BuildContext context, Object error)? onRefreshError;

  static Widget _loading(BuildContext context) => const Center(child: CircularProgressIndicator.adaptive());

  static Widget _error(BuildContext context, Object error, VoidCallback? retry) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('$error', textAlign: TextAlign.center),
        if (retry != null) TextButton(onPressed: retry, child: const Text('Retry')),
      ],
    ),
  );

  static const _fallback = AsyncViewDefaults(child: SizedBox.shrink());

  /// The nearest defaults, or the built-in ones.
  static AsyncViewDefaults of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AsyncViewDefaults>() ?? _fallback;

  @override
  bool updateShouldNotify(AsyncViewDefaults oldWidget) =>
      loading != oldWidget.loading || error != oldWidget.error || onRefreshError != oldWidget.onRefreshError;
}

/// Renders an [Async]: [builder] when there is a value (also while refreshing or after a
/// failed refresh), otherwise the loading or error widget of [AsyncViewDefaults].
///
/// A refresh that fails while a value is shown is reported once through
/// [AsyncViewDefaults.onRefreshError]. With [onRefresh], the content can be pulled to refresh.
class AsyncView<T> extends StatefulWidget {
  /// Renders [value].
  const AsyncView(
    this.value, {
    super.key,
    required this.builder,
    this.onRetry,
    this.onRefresh,
    this.loading,
    this.error,
  });

  /// What to render.
  final Async<T> value;

  /// Builds the content from the value.
  final Widget Function(BuildContext context, T value) builder;

  /// Offered on the error widget.
  final VoidCallback? onRetry;

  /// Enables pull to refresh. The content must be scrollable.
  final Future<void> Function()? onRefresh;

  /// Overrides [AsyncViewDefaults.loading].
  final WidgetBuilder? loading;

  /// Overrides [AsyncViewDefaults.error].
  final AsyncErrorBuilder? error;

  @override
  State<AsyncView<T>> createState() => _AsyncViewState<T>();
}

class _AsyncViewState<T> extends State<AsyncView<T>> {
  @override
  void didUpdateWidget(AsyncView<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    final value = widget.value;
    if (value is AsyncFailure<T> && value.hasValue && value != oldWidget.value) {
      final report = AsyncViewDefaults.of(context).onRefreshError;
      if (report != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) report(context, value.error);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final value = widget.value;
    if (value.hasValue) {
      final content = widget.builder(context, value.value);
      final onRefresh = widget.onRefresh;
      return onRefresh == null ? content : RefreshIndicator.adaptive(onRefresh: onRefresh, child: content);
    }
    final defaults = AsyncViewDefaults.of(context);
    return switch (value) {
      AsyncFailure(:final error) => (widget.error ?? defaults.error)(context, error, widget.onRetry),
      _ => (widget.loading ?? defaults.loading)(context),
    };
  }
}
