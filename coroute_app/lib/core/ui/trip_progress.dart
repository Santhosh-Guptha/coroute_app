import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import 'stop_kind.dart';
import 'ui_format.dart';
import 'ui_tokens.dart';

/// One stop in a [TripProgress] list.
@immutable
class TripProgressStop {
  final String name;
  final StopKind kind;

  /// Distance from me along the route, in km. Shown for stops not done yet.
  final double? kmFromMe;
  final bool done;

  const TripProgressStop({
    required this.name,
    this.kind = StopKind.custom,
    this.kmFromMe,
    this.done = false,
  });
}

/// Vertical trip progress: a tick for each stop done, a dot for "You are
/// here", then the next stops with their distance.
///
/// [currentIndex] is the index of the next stop (the "You are here" row is
/// drawn just before it). When null it is the first stop not done. Not
/// scrollable on its own: put it in a scroll view or a sheet.
class TripProgress extends StatelessWidget {
  final List<TripProgressStop> stops;
  final int? currentIndex;

  const TripProgress({super.key, required this.stops, this.currentIndex});

  int get _current {
    final c = currentIndex;
    if (c != null) return c.clamp(0, stops.length).toInt();
    final i = stops.indexWhere((s) => !s.done);
    return i < 0 ? stops.length : i;
  }

  @override
  Widget build(BuildContext context) {
    final cur = _current;
    final rows = <Widget>[];
    for (var i = 0; i <= stops.length; i++) {
      if (i == cur) rows.add(const _HereRow());
      if (i < stops.length) rows.add(_StopRow(stop: stops[i], upcoming: i >= cur));
    }
    final children = <Widget>[];
    for (var i = 0; i < rows.length; i++) {
      if (i > 0) children.add(const _Connector());
      children.add(rows[i]);
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    );
  }
}

const double _railWidth = 32;

class _Connector extends StatelessWidget {
  const _Connector();

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: AlignmentDirectional.centerStart,
      child: SizedBox(
        width: _railWidth,
        height: Space.s8,
        child: Center(child: Container(width: 2, color: AppTheme.subtleBorder)),
      ),
    );
  }
}

class _HereRow extends StatelessWidget {
  const _HereRow();

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      label: 'You are here',
      excludeSemantics: true,
      child: Row(
        children: [
          SizedBox(
            width: _railWidth,
            height: _railWidth,
            child: Center(
              child: Container(
                width: 16,
                height: 16,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: AppTheme.neonCyan,
                  border: Border.all(color: AppTheme.slateCard, width: 3),
                ),
              ),
            ),
          ),
          const SizedBox(width: Space.s12),
          Expanded(
            child: Text(
              'You are here',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppText.label.copyWith(color: AppTheme.neonCyan),
            ),
          ),
        ],
      ),
    );
  }
}

class _StopRow extends StatelessWidget {
  final TripProgressStop stop;
  final bool upcoming;

  const _StopRow({required this.stop, required this.upcoming});

  @override
  Widget build(BuildContext context) {
    final done = stop.done;
    final km = stop.kmFromMe;
    final String? distance = (!done && upcoming && km != null) ? formatDistanceRounded(km * 1000) : null;
    final name = stop.name.isEmpty ? stop.kind.label : stop.name;
    final semantic = done
        ? '${stop.kind.label}, $name, done'
        : (distance == null ? '${stop.kind.label}, $name' : '${stop.kind.label}, $name, $distance');
    return Semantics(
      container: true,
      label: semantic,
      excludeSemantics: true,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 40),
        child: Row(
          children: [
            SizedBox(
              width: _railWidth,
              height: _railWidth,
              child: done
                  ? Icon(Icons.check_circle_rounded, size: 22, color: StatusColors.success)
                  : Icon(stop.kind.icon, size: 22, color: upcoming ? AppTheme.textPrimary : AppTheme.textMuted),
            ),
            const SizedBox(width: Space.s12),
            Expanded(
              child: Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppText.body.copyWith(color: done ? AppTheme.textSecondary : AppTheme.textPrimary),
              ),
            ),
            if (distance != null) ...[
              const SizedBox(width: Space.s8),
              Text(
                distance,
                maxLines: 1,
                style: AppText.label.copyWith(
                  color: AppTheme.textPrimary,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
