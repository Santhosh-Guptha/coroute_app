import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

/// Loading that never blocks: the [child] (old data) stays visible and a
/// thin progress line runs along the top while [loading].
///
/// Only when there is nothing to show yet ([hasData] false) a small
/// centred spinner is shown instead of the child.
class LoadingState extends StatelessWidget {
  final bool loading;
  final bool hasData;
  final Widget child;

  const LoadingState({
    super.key,
    required this.loading,
    required this.child,
    this.hasData = true,
  });

  @override
  Widget build(BuildContext context) {
    if (!hasData && loading) return const LoadingSpinner();
    return Stack(
      fit: StackFit.passthrough,
      children: [
        child,
        if (loading)
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: Semantics(
              label: 'Loading',
              liveRegion: true,
              child: LinearProgressIndicator(
                minHeight: 2,
                color: AppTheme.neonCyan,
                backgroundColor: Colors.transparent,
              ),
            ),
          ),
      ],
    );
  }
}

/// Small centred spinner, for a screen or section with no data yet.
class LoadingSpinner extends StatelessWidget {
  const LoadingSpinner({super.key});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Semantics(
        label: 'Loading',
        child: SizedBox(
          width: 24,
          height: 24,
          child: CircularProgressIndicator(strokeWidth: 2.5, color: AppTheme.neonCyan),
        ),
      ),
    );
  }
}
