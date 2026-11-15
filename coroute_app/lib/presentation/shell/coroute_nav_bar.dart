import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../core/ui/coroute_logo.dart';
import '../../core/ui/ui.dart';

/// The four destinations of the bottom bar (the centre "+" is an action, not a destination).
enum NavSlot { home, explore, community, chat }

/// v3.58 bottom bar: Home · Explore · ( Ride ) · Community · Chat (v3.59 look: road-shaped Ride key, lane marks).
///
/// * Glove-friendly: every slot is at least 48 dp wide and 64 dp tall; the "+" is a 56 dp disc.
/// * [selected] null = a screen that is not in the bar (Profile, Trips, Alerts): nothing is highlighted.
/// * Badges are numbers with a spoken label, never colour alone.
/// * Selection haptic on tap; the selected slot gets a short teal line on top and a filled icon.
class CoRouteNavBar extends StatelessWidget {
  final NavSlot? selected;
  final ValueChanged<NavSlot> onSelect;
  final VoidCallback onPlus;
  final Map<NavSlot, int> badges;

  /// Spoken with a badge, per slot ("2 alerts need attention").
  final Map<NavSlot, String> badgeLabels;

  const CoRouteNavBar({super.key, required this.selected, required this.onSelect, required this.onPlus, this.badges = const {}, this.badgeLabels = const {}});

  static const double barHeight = 68;
  static const double plusSize = 56;

  static const Map<NavSlot, (IconData, IconData, String)> _items = {
    NavSlot.home: (Icons.home_outlined, Icons.home_rounded, 'Home'),
    NavSlot.explore: (Icons.explore_outlined, Icons.explore_rounded, 'Explore'),
    NavSlot.community: (Icons.groups_outlined, Icons.groups_rounded, 'Community'),
    NavSlot.chat: (Icons.chat_bubble_outline_rounded, Icons.chat_bubble_rounded, 'Chat'),
  };

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.paddingOf(context).bottom;
    Widget slot(NavSlot s) => Expanded(child: _NavItem(slot: s, item: _items[s]!, selected: selected == s, badge: badges[s] ?? 0, badgeLabel: badgeLabels[s], onTap: () => onSelect(s)));
    return Container(
      key: const Key('coroute_nav_bar'),
      // v3.59: CoRoute's own bar: rounded top, soft lift, a road-shaped "Ride" key in the centre, and amber lane
      // marks under the selected tab (not the usual pill or top line).
      decoration: BoxDecoration(
        color: AppTheme.card,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(22)),
        border: Border(top: BorderSide(color: AppTheme.border)),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: AppTheme.isLight ? 0.06 : 0.3), blurRadius: 16, offset: const Offset(0, -4))],
      ),
      padding: EdgeInsets.only(bottom: bottom),
      child: SizedBox(
        height: barHeight,
        child: Row(
          children: [
            slot(NavSlot.home),
            slot(NavSlot.explore),
            Expanded(
              child: Center(
                child: Semantics(
                  button: true,
                  label: 'Ride: start a ride, join with a code, plan a trip, emergency',
                  excludeSemantics: true,
                  child: Pressable(
                    key: const Key('nav_plus'),
                    haptic: AppHaptic.medium,
                    onTap: onPlus,
                    child: Container(
                      width: plusSize + 8,
                      height: 52,
                      decoration: BoxDecoration(color: AppTheme.primaryFill, borderRadius: BorderRadius.circular(18), boxShadow: dsFloatingShadow()),
                      clipBehavior: Clip.antiAlias,
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          // A short road across the key: CoRoute's mark for "ride".
                          Positioned(left: 8, right: 8, bottom: 7, child: RoadStripe(axis: Axis.horizontal, width: 4, road: Colors.white.withValues(alpha: 0.18))),
                          Padding(
                            padding: const EdgeInsets.only(bottom: 6),
                            child: Icon(Icons.two_wheeler_rounded, size: 26, color: AppTheme.onPrimary),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
            slot(NavSlot.community),
            slot(NavSlot.chat),
          ],
        ),
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  final NavSlot slot;
  final (IconData, IconData, String) item;
  final bool selected;
  final int badge;
  final String? badgeLabel;
  final VoidCallback onTap;
  const _NavItem({required this.slot, required this.item, required this.selected, required this.badge, required this.badgeLabel, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final color = selected ? AppTheme.primary : AppTheme.text2;
    Widget icon = Icon(selected ? item.$2 : item.$1, size: 24, color: color);
    if (badge > 0) icon = Badge(label: Text(badge > 9 ? '9+' : '$badge'), child: icon);
    return Semantics(
      key: Key('nav_${slot.name}'),
      selected: selected,
      button: true,
      label: badge > 0 && badgeLabel != null ? '${item.$3}, $badgeLabel' : item.$3,
      excludeSemantics: true,
      child: InkWell(
        onTap: () {
          AppHaptics.selection();
          onTap();
        },
        child: ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              icon,
              const SizedBox(height: 4),
              Text(
                item.$3,
                maxLines: 1,
                overflow: TextOverflow.fade,
                softWrap: false,
                // The bar keeps its height at large text: labels scale only a little.
                textScaler: MediaQuery.textScalerOf(context).clamp(maxScaleFactor: 1.15),
                style: TextStyle(fontSize: 12, height: 1.2, color: color, fontWeight: selected ? FontWeight.w600 : FontWeight.w500),
              ),
              const SizedBox(height: 4),
              // Selected: two amber lane marks (a road's centre line), not a pill.
              AnimatedOpacity(
                duration: Motion.tab,
                opacity: selected ? 1 : 0,
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  for (var i = 0; i < 2; i++) ...[
                    if (i > 0) const SizedBox(width: 3),
                    Container(width: 7, height: 3, decoration: BoxDecoration(color: CoRouteBrand.amber, borderRadius: BorderRadius.circular(2))),
                  ],
                ]),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
