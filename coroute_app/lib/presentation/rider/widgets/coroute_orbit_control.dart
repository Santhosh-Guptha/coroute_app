import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/ui/ui_tokens.dart';

/// Draggable CoRoute Orbit Control FAB and In-Cockpit Quick Access HUD Popup.
///
/// Features:
/// - Draggable 52dp thumb FAB that magnetically snaps to left or right handlebar edges.
/// - Glowing amber orbit rings emblem matching motorcycle cockpit ergonomics.
/// - In-cockpit 6-tile Quick Access Popup (Intercom, Group, Fuel, Route, Guardian, More).
/// - 100% in-cockpit popup architecture: never navigates away from the live map.
/// - Buttery-smooth spring animations and haptic feedback.
class CorouteOrbitControl extends StatefulWidget {
  final VoidCallback onIntercomTap;
  final VoidCallback onGroupTap;
  final VoidCallback onFuelTap;
  final VoidCallback onRouteTap;
  final VoidCallback onGuardianTap;
  final VoidCallback onMoreTap;

  const CorouteOrbitControl({
    super.key,
    required this.onIntercomTap,
    required this.onGroupTap,
    required this.onFuelTap,
    required this.onRouteTap,
    required this.onGuardianTap,
    required this.onMoreTap,
  });

  @override
  State<CorouteOrbitControl> createState() => _CorouteOrbitControlState();
}

class _CorouteOrbitControlState extends State<CorouteOrbitControl>
    with SingleTickerProviderStateMixin {
  late final AnimationController _animController;
  late final Animation<double> _scaleAnimation;
  late final Animation<double> _fadeAnimation;

  Offset? _position;
  bool _isOpen = false;
  bool _isDragging = false;

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 240),
    );
    _scaleAnimation = CurvedAnimation(
      parent: _animController,
      curve: Curves.easeOutBack,
      reverseCurve: Curves.easeIn,
    );
    _fadeAnimation = CurvedAnimation(
      parent: _animController,
      curve: Curves.easeOut,
    );
  }

  @override
  void dispose() {
    _animController.dispose();
    super.dispose();
  }

  void _togglePopup() {
    HapticFeedback.lightImpact();
    setState(() {
      _isOpen = !_isOpen;
      if (_isOpen) {
        _animController.forward();
      } else {
        _animController.reverse();
      }
    });
  }

  void _closePopup() {
    if (!_isOpen) return;
    HapticFeedback.selectionClick();
    setState(() {
      _isOpen = false;
      _animController.reverse();
    });
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;

    // Default initial position on right edge, mid-height
    _position ??= Offset(size.width - 68, (size.height * 0.42).clamp(160.0, size.height - 240));

    final orbitFab = GestureDetector(
      key: const Key('coroute_orbit_fab_button'),
      onPanStart: (_) {
        setState(() => _isDragging = true);
      },
      onPanUpdate: (details) {
        setState(() {
          final newX = (_position!.dx + details.delta.dx)
              .clamp(12.0, (size.width - 64).clamp(12.0, double.infinity));
          final newY = (_position!.dy + details.delta.dy)
              .clamp(100.0, (size.height - 220).clamp(100.0, double.infinity));
          _position = Offset(newX, newY);
        });
      },
      onPanEnd: (_) {
        // Buttery-smooth magnetic snap to nearest edge
        HapticFeedback.lightImpact();
        final snapX = (_position!.dx < size.width / 2) ? 14.0 : (size.width - 66.0);
        setState(() {
          _isDragging = false;
          _position = Offset(snapX, _position!.dy);
        });
      },
      onTap: _togglePopup,
      child: AnimatedContainer(
        duration: _isDragging ? Duration.zero : const Duration(milliseconds: 260),
        curve: Curves.easeOutCubic,
        width: 52,
        height: 52,
        decoration: BoxDecoration(
          color: isDark ? const Color(0xFF0A0E17) : Colors.white,
          shape: BoxShape.circle,
          border: Border.all(
            color: AppTheme.hyperAmber,
            width: 2.4,
          ),
          boxShadow: [
            BoxShadow(
              color: AppTheme.hyperAmber.withOpacity(isDark ? 0.45 : 0.25),
              blurRadius: 12,
              spreadRadius: 2,
            ),
          ],
        ),
        child: const Center(
          child: _OrbitRingsIcon(),
        ),
      ),
    );

    return Stack(
      children: [
        // Non-blocking backdrop when popup is open
        if (_isOpen)
          Positioned.fill(
            child: GestureDetector(
              onTap: _closePopup,
              behavior: HitTestBehavior.opaque,
              child: AnimatedBuilder(
                animation: _fadeAnimation,
                builder: (context, _) => Container(
                  color: Colors.black.withOpacity(0.45 * _fadeAnimation.value),
                ),
              ),
            ),
          ),

        // Floating popup card
        if (_isOpen)
          Positioned(
            left: 20,
            right: 20,
            top: (_position!.dy - 120).clamp(120.0, (size.height - 340).clamp(120.0, double.infinity)),
            child: AnimatedBuilder(
              animation: _animController,
              builder: (context, child) {
                return Opacity(
                  opacity: _fadeAnimation.value,
                  child: Transform.scale(
                    scale: _scaleAnimation.value,
                    alignment: _position!.dx < size.width / 2
                        ? Alignment.centerLeft
                        : Alignment.centerRight,
                    child: child,
                  ),
                );
              },
              child: _OrbitQuickAccessCard(
                isDark: isDark,
                onClose: _closePopup,
                onIntercomTap: () {
                  _closePopup();
                  widget.onIntercomTap();
                },
                onGroupTap: () {
                  _closePopup();
                  widget.onGroupTap();
                },
                onFuelTap: () {
                  _closePopup();
                  widget.onFuelTap();
                },
                onRouteTap: () {
                  _closePopup();
                  widget.onRouteTap();
                },
                onGuardianTap: () {
                  _closePopup();
                  widget.onGuardianTap();
                },
                onMoreTap: () {
                  _closePopup();
                  widget.onMoreTap();
                },
              ),
            ),
          ),

        // The draggable floating FAB
        Positioned(
          left: _position!.dx,
          top: _position!.dy,
          child: orbitFab,
        ),
      ],
    );
  }
}

/// Custom orbital atom emblem for CoRoute Orbit FAB.
class _OrbitRingsIcon extends StatelessWidget {
  const _OrbitRingsIcon();

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: const Size(28, 28),
      painter: _OrbitPainter(color: AppTheme.hyperAmber),
    );
  }
}

class _OrbitPainter extends CustomPainter {
  final Color color;
  const _OrbitPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8;

    final center = Offset(size.width / 2, size.height / 2);

    // Orbit ellipse 1 (-30 deg)
    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.rotate(-0.523);
    canvas.drawOval(
      Rect.fromCenter(center: Offset.zero, width: size.width * 0.95, height: size.height * 0.42),
      paint,
    );
    canvas.restore();

    // Orbit ellipse 2 (+30 deg)
    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.rotate(0.523);
    canvas.drawOval(
      Rect.fromCenter(center: Offset.zero, width: size.width * 0.95, height: size.height * 0.42),
      paint,
    );
    canvas.restore();

    // Center atomic nucleus
    final fillPaint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;
    canvas.drawCircle(center, 3.2, fillPaint);
  }

  @override
  bool shouldRepaint(covariant _OrbitPainter oldDelegate) => oldDelegate.color != color;
}

/// The In-Cockpit CoRoute Orbit Quick Access Popup Card (2 rows x 3 cols).
class _OrbitQuickAccessCard extends StatelessWidget {
  final bool isDark;
  final VoidCallback onClose;
  final VoidCallback onIntercomTap;
  final VoidCallback onGroupTap;
  final VoidCallback onFuelTap;
  final VoidCallback onRouteTap;
  final VoidCallback onGuardianTap;
  final VoidCallback onMoreTap;

  const _OrbitQuickAccessCard({
    required this.isDark,
    required this.onClose,
    required this.onIntercomTap,
    required this.onGroupTap,
    required this.onFuelTap,
    required this.onRouteTap,
    required this.onGuardianTap,
    required this.onMoreTap,
  });

  @override
  Widget build(BuildContext context) {
    final cardBg = isDark ? const Color(0xFF0F1622) : Colors.white;
    final cyan = isDark ? AppTheme.neonCyan : const Color(0xFF00838F);

    return Container(
      padding: const EdgeInsets.all(Space.s16),
      decoration: BoxDecoration(
        color: cardBg,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: cyan, width: 1.8),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(isDark ? 0.5 : 0.18),
            blurRadius: 24,
            spreadRadius: 4,
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header Row: COROUTE ORBIT + QUICK ACCESS badge + Close
          Row(
            children: [
              Text(
                'COROUTE ORBIT',
                style: AppText.title.copyWith(
                  fontWeight: FontWeight.w900,
                  letterSpacing: 1.2,
                  color: isDark ? Colors.white : AppTheme.obsidianVoid,
                ),
              ),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: Space.s8, vertical: 3),
                decoration: BoxDecoration(
                  color: isDark ? cyan.withOpacity(0.15) : const Color(0xFFE0F2FE),
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(color: cyan, width: 0.8),
                ),
                child: Text(
                  'QUICK ACCESS',
                  style: AppText.caption.copyWith(
                    fontWeight: FontWeight.w800,
                    color: cyan,
                    letterSpacing: 0.5,
                  ),
                ),
              ),
              const SizedBox(width: Space.s8),
              IconButton(
                visualDensity: VisualDensity.compact,
                icon: Icon(
                  Icons.close_rounded,
                  size: 18,
                  color: AppTheme.textSecondary,
                ),
                onPressed: onClose,
              ),
            ],
          ),
          const SizedBox(height: Space.s12),

          // 2 Rows x 3 Columns Glove Action Tiles Grid
          Row(
            children: [
              Expanded(
                child: _OrbitTile(
                  icon: Icons.record_voice_over_rounded,
                  label: 'Intercom',
                  isDark: isDark,
                  onTap: onIntercomTap,
                ),
              ),
              const SizedBox(width: Space.s8),
              Expanded(
                child: _OrbitTile(
                  icon: Icons.group_rounded,
                  label: 'Group',
                  isDark: isDark,
                  onTap: onGroupTap,
                ),
              ),
              const SizedBox(width: Space.s8),
              Expanded(
                child: _OrbitTile(
                  icon: Icons.local_gas_station_rounded,
                  label: 'Fuel',
                  isDark: isDark,
                  onTap: onFuelTap,
                ),
              ),
            ],
          ),
          const SizedBox(height: Space.s8),
          Row(
            children: [
              Expanded(
                child: _OrbitTile(
                  icon: Icons.alt_route_rounded,
                  label: 'Route',
                  isDark: isDark,
                  onTap: onRouteTap,
                ),
              ),
              const SizedBox(width: Space.s8),
              Expanded(
                child: _OrbitTile(
                  icon: Icons.shield_rounded,
                  label: 'Guardian',
                  isDark: isDark,
                  onTap: onGuardianTap,
                ),
              ),
              const SizedBox(width: Space.s8),
              Expanded(
                child: _OrbitTile(
                  icon: Icons.grid_view_rounded,
                  label: 'More',
                  isDark: isDark,
                  onTap: onMoreTap,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _OrbitTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool isDark;
  final VoidCallback onTap;

  const _OrbitTile({
    required this.icon,
    required this.label,
    required this.isDark,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final tileBg = isDark ? const Color(0xFF162030) : const Color(0xFFF1F5F9);
    final tileBorder = isDark ? AppTheme.subtleBorder : const Color(0xFFE2E8F0);
    final cyan = isDark ? AppTheme.neonCyan : const Color(0xFF00838F);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () {
          HapticFeedback.lightImpact();
          onTap();
        },
        borderRadius: Radii.lgAll,
        child: Container(
          height: 72,
          decoration: BoxDecoration(
            color: tileBg,
            borderRadius: Radii.lgAll,
            border: Border.all(color: tileBorder, width: 1),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, color: cyan, size: 24),
              const SizedBox(height: Space.s4),
              Text(
                label,
                style: AppText.caption.copyWith(
                  fontWeight: FontWeight.w700,
                  color: isDark ? Colors.white : AppTheme.obsidianVoid,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
