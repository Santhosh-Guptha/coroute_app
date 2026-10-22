import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/ui/ui.dart';

/// Draggable CoRoute Orbit Control button and In-Cockpit Quick Access panel.
///
/// Features:
/// - Draggable 60 dp round thumb button (3 px teal ring) that magnetically
///   snaps to the left or right handlebar edge.
/// - While open the ring turns amber with a soft amber glow and a dim scrim
///   covers the map (tap outside to close).
/// - In-cockpit 6-tile Quick Access panel (Intercom, Group, Fuel, Route,
///   Guardian, More) plus an optional full-width Emergency SOS button.
/// - 100% in-cockpit popup architecture: never navigates away from the live map.
class CorouteOrbitControl extends StatefulWidget {
  final VoidCallback onIntercomTap;
  final VoidCallback onGroupTap;
  final VoidCallback onFuelTap;
  final VoidCallback onRouteTap;
  final VoidCallback onGuardianTap;
  final VoidCallback onMoreTap;

  /// Shown as a solid red "Emergency SOS" button at the bottom of the panel
  /// when given.
  final VoidCallback? onSosTap;

  const CorouteOrbitControl({
    super.key,
    required this.onIntercomTap,
    required this.onGroupTap,
    required this.onFuelTap,
    required this.onRouteTap,
    required this.onGuardianTap,
    required this.onMoreTap,
    this.onSosTap,
  });

  @override
  State<CorouteOrbitControl> createState() => _CorouteOrbitControlState();
}

class _CorouteOrbitControlState extends State<CorouteOrbitControl>
    with SingleTickerProviderStateMixin {
  static const double _fabSize = 60;
  static const double _edgeGap = 16;

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
      curve: Curves.easeOutCubic,
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
    final padding = MediaQuery.paddingOf(context);
    final maxX = (size.width - _fabSize - _edgeGap).clamp(12.0, double.infinity);

    // Default initial position on the left edge, above the middle of the screen (canvas: top 320).
    _position ??= Offset(_edgeGap, (size.height * 0.38).clamp(160.0, (size.height - 260).clamp(160.0, double.infinity)));

    final onLeft = _position!.dx < size.width / 2;
    final ringColor = _isOpen ? AppTheme.warnText : AppTheme.accentText;

    final orbitFab = GestureDetector(
      key: const Key('coroute_orbit_fab_button'),
      onPanStart: (_) {
        setState(() => _isDragging = true);
      },
      onPanUpdate: (details) {
        setState(() {
          final newX = (_position!.dx + details.delta.dx).clamp(12.0, maxX);
          final newY = (_position!.dy + details.delta.dy)
              .clamp(100.0, (size.height - 220).clamp(100.0, double.infinity));
          _position = Offset(newX, newY);
        });
      },
      onPanEnd: (_) {
        // Magnetic snap to the nearest edge.
        HapticFeedback.lightImpact();
        final snapX = (_position!.dx < size.width / 2) ? _edgeGap : maxX;
        setState(() {
          _isDragging = false;
          _position = Offset(snapX, _position!.dy);
        });
      },
      onTap: _togglePopup,
      child: Semantics(
        button: true,
        label: _isOpen ? 'Close Orbit quick access' : 'Open Orbit quick access',
        child: AnimatedContainer(
          duration: _isDragging ? Duration.zero : const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          width: _fabSize,
          height: _fabSize,
          decoration: BoxDecoration(
            color: AppTheme.card,
            shape: BoxShape.circle,
            border: Border.all(color: ringColor, width: 3),
            boxShadow: _isOpen
                ? [
                    BoxShadow(
                      color: AppTheme.warnText.withOpacity(0.25),
                      spreadRadius: 8,
                      blurRadius: 0,
                    ),
                  ]
                : [
                    BoxShadow(
                      color: AppTheme.shadow.withOpacity(AppTheme.isLight ? 0.16 : 0.5),
                      blurRadius: 16,
                      offset: const Offset(0, 6),
                    ),
                  ],
          ),
          child: Center(child: _OrbitRingsIcon(color: ringColor)),
        ),
      ),
    );

    return Stack(
      children: [
        // Dim scrim when the panel is open: tap anywhere outside to close.
        if (_isOpen)
          Positioned.fill(
            child: GestureDetector(
              onTap: _closePopup,
              behavior: HitTestBehavior.opaque,
              child: AnimatedBuilder(
                animation: _fadeAnimation,
                builder: (context, _) => Container(
                  color: const Color(0xFF15232E).withOpacity(0.55 * _fadeAnimation.value),
                ),
              ),
            ),
          ),

        if (_isOpen)
          Positioned(
            left: 0,
            right: 0,
            bottom: padding.bottom + 36,
            child: IgnorePointer(
              child: AnimatedBuilder(
                animation: _fadeAnimation,
                builder: (context, _) => Opacity(
                  opacity: _fadeAnimation.value,
                  child: const Text(
                    'Tap outside to close',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w700),
                  ),
                ),
              ),
            ),
          ),

        // Floating quick-access panel beside the button.
        if (_isOpen)
          Positioned(
            left: onLeft ? _edgeGap + _fabSize + 16 : null,
            right: onLeft ? null : _edgeGap + _fabSize + 16,
            width: (size.width - _fabSize - _edgeGap * 2 - 16).clamp(280.0, 360.0),
            top: (_position!.dy - 70).clamp(padding.top + 12, (size.height - 400).clamp(padding.top + 12, double.infinity)),
            child: AnimatedBuilder(
              animation: _animController,
              builder: (context, child) {
                return Opacity(
                  opacity: _fadeAnimation.value,
                  child: Transform.scale(
                    scale: 0.92 + 0.08 * _scaleAnimation.value,
                    alignment: onLeft ? Alignment.centerLeft : Alignment.centerRight,
                    child: child,
                  ),
                );
              },
              child: _OrbitQuickAccessCard(
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
                onSosTap: widget.onSosTap == null
                    ? null
                    : () {
                        _closePopup();
                        widget.onSosTap!();
                      },
              ),
            ),
          ),

        // The draggable floating button.
        Positioned(
          left: _position!.dx,
          top: _position!.dy,
          child: orbitFab,
        ),
      ],
    );
  }
}

/// Orbit emblem (three ellipses around a nucleus) for the Orbit button.
class _OrbitRingsIcon extends StatelessWidget {
  final Color color;
  const _OrbitRingsIcon({required this.color});

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: const Size(30, 30),
      painter: _OrbitPainter(color: color),
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
      ..strokeWidth = 2;

    final center = Offset(size.width / 2, size.height / 2);
    final rect = Rect.fromCenter(center: Offset.zero, width: size.width * 0.9, height: size.height * 0.36);

    for (final angle in const [0.0, 1.0472, 2.0944]) {
      canvas.save();
      canvas.translate(center.dx, center.dy);
      canvas.rotate(angle);
      canvas.drawOval(rect, paint);
      canvas.restore();
    }

    final fillPaint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;
    canvas.drawCircle(center, 2.2, fillPaint);
  }

  @override
  bool shouldRepaint(covariant _OrbitPainter oldDelegate) => oldDelegate.color != color;
}

/// The In-Cockpit CoRoute Orbit Quick Access panel (3 x 2 tiles + SOS).
class _OrbitQuickAccessCard extends StatelessWidget {
  final VoidCallback onIntercomTap;
  final VoidCallback onGroupTap;
  final VoidCallback onFuelTap;
  final VoidCallback onRouteTap;
  final VoidCallback onGuardianTap;
  final VoidCallback onMoreTap;
  final VoidCallback? onSosTap;

  const _OrbitQuickAccessCard({
    required this.onIntercomTap,
    required this.onGroupTap,
    required this.onFuelTap,
    required this.onRouteTap,
    required this.onGuardianTap,
    required this.onMoreTap,
    this.onSosTap,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AppTheme.card,
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(color: AppTheme.shadow, blurRadius: 40, offset: const Offset(0, 16)),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Flexible(
                child: Text('COROUTE ORBIT', maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.overline),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
                decoration: BoxDecoration(
                  color: AppTheme.tint,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  'QUICK ACCESS',
                  style: TextStyle(
                    color: AppTheme.accentText,
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(child: _OrbitTile(icon: Icons.mic_rounded, label: 'Intercom', onTap: onIntercomTap)),
              const SizedBox(width: 10),
              Expanded(child: _OrbitTile(icon: Icons.group_outlined, label: 'Group', onTap: onGroupTap)),
              const SizedBox(width: 10),
              Expanded(child: _OrbitTile(icon: Icons.local_gas_station_outlined, label: 'Fuel', onTap: onFuelTap)),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(child: _OrbitTile(icon: Icons.route_outlined, label: 'Route', onTap: onRouteTap)),
              const SizedBox(width: 10),
              Expanded(child: _OrbitTile(icon: Icons.verified_user_outlined, label: 'Guardian', onTap: onGuardianTap)),
              const SizedBox(width: 10),
              Expanded(child: _OrbitTile(icon: Icons.grid_view_rounded, label: 'More', onTap: onMoreTap)),
            ],
          ),
          if (onSosTap != null) ...[
            const SizedBox(height: 14),
            DsButton(
              label: 'Emergency SOS',
              icon: Icons.warning_amber_rounded,
              tone: DsButtonTone.sos,
              height: 52,
              fontSize: 14,
              onPressed: () {
                HapticFeedback.mediumImpact();
                onSosTap!();
              },
            ),
          ],
        ],
      ),
    );
  }
}

class _OrbitTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _OrbitTile({required this.icon, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return DsIconTile(
      icon: icon,
      label: label,
      height: 86,
      iconSize: 26,
      fontSize: 12,
      onTap: () {
        HapticFeedback.lightImpact();
        onTap();
      },
    );
  }
}
