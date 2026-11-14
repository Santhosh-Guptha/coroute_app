import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../core/ui/ui.dart';

/// The four destinations of the bottom bar (the centre "+" is an action, not a destination).
enum NavSlot { home, explore, community, chat }

/// v3.58 bottom bar: Home · Explore · ( + ) · Community · Chat.
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
      decoration: BoxDecoration(color: AppTheme.card, border: Border(top: BorderSide(color: AppTheme.border))),
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
                  label: 'Quick actions: start a ride, join with a code, plan a trip, emergency',
                  child: Pressable(
                    key: const Key('nav_plus'),
                    haptic: AppHaptic.medium,
                    onTap: onPlus,
                    child: Container(
                      width: plusSize,
                      height: plusSize,
                      decoration: BoxDecoration(color: AppTheme.primary, shape: BoxShape.circle, boxShadow: dsFloatingShadow()),
                      child: Icon(Icons.add_rounded, size: 30, color: AppTheme.onPrimary),
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
              AnimatedContainer(
                duration: Motion.tab,
                curve: Motion.curve,
                width: selected ? 24 : 0,
                height: 3,
                margin: const EdgeInsets.only(bottom: 6),
                decoration: BoxDecoration(color: AppTheme.primary, borderRadius: BorderRadius.circular(2)),
              ),
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
            ],
          ),
        ),
      ),
    );
  }
}
