import 'package:flutter/foundation.dart';
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
  final bool isSolo;

  /// Visible height of the ride sheet from the bottom of the screen. The
  /// button is kept above it (plus [sheetClearance]) so it never covers the
  /// sheet, the SOS button or the map controls riding on the sheet's edge.
  final ValueListenable<double>? sheetHeight;

  /// How far the ride sheet is open (0 collapsed, 1 expanded). The closed
  /// button fades out as the sheet opens, like the other floating controls.
  final ValueListenable<double>? sheetExpansion;

  /// Extra room kept free between the sheet's top edge and the button.
  final double sheetClearance;

  /// Space taken on the left by a side panel (landscape ride sheet): the
  /// button snaps to the right of it instead of over it.
  final double leftInset;

  const CorouteOrbitControl({
    super.key,
    required this.onIntercomTap,
    required this.onGroupTap,
    required this.onFuelTap,
    required this.onRouteTap,
    required this.onGuardianTap,
    required this.onMoreTap,
    this.onSosTap,
    this.isSolo = false,
    this.sheetHeight,
    this.sheetExpansion,
    this.sheetClearance = 0,
    this.leftInset = 0,
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

  /// Where the button was last drawn (its stored position pushed up above the
  /// sheet when needed); a drag starts from here so it never feels stuck.
  double? _shownTop;

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
    final leftEdge = widget.leftInset + _edgeGap;
    final minX = (widget.leftInset + 12.0).clamp(12.0, double.infinity).toDouble();
    final maxX = (size.width - padding.right - _fabSize - _edgeGap).clamp(minX, double.infinity).toDouble();

    // Default initial position on the left edge, above the middle of the screen (canvas: top 320).
    _position ??= Offset(leftEdge, (size.height * 0.38).clamp(160.0, (size.height - 260).clamp(160.0, double.infinity)));
    // Keep it on screen after a rotation or a side panel appearing.
    if (_position!.dx < minX || _position!.dx > maxX) {
      _position = Offset(_position!.dx.clamp(minX, maxX).toDouble(), _position!.dy);
    }

    final onLeft = _position!.dx < (widget.leftInset + size.width) / 2;

    // Quick-access panel beside the button: 280 to 360 dp wide, and kept on
    // screen on narrow phones (it may then overlap the button a little).
    final maxPanelW = (size.width - widget.leftInset - padding.right - 24).clamp(200.0, double.infinity).toDouble();
    final panelW = (size.width - widget.leftInset - padding.right - _fabSize - _edgeGap * 2 - 16)
        .clamp(280.0, 360.0)
        .toDouble()
        .clamp(0.0, maxPanelW)
        .toDouble();
    final panelLeft = (leftEdge + _fabSize + 16)
        .clamp(widget.leftInset + 12, (size.width - padding.right - 12 - panelW).clamp(widget.leftInset + 12, double.infinity))
        .toDouble();
    final panelRight = (_edgeGap + padding.right + _fabSize + 16)
        .clamp(padding.right + 12, (size.width - widget.leftInset - 12 - panelW).clamp(padding.right + 12, double.infinity))
        .toDouble();
    final ringColor = _isOpen ? AppTheme.warnText : AppTheme.accentText;

    final orbitFab = GestureDetector(
      key: const Key('coroute_orbit_fab_button'),
      onPanStart: (_) {
        setState(() {
          _isDragging = true;
          final shown = _shownTop;
          if (shown != null) _position = Offset(_position!.dx, shown);
        });
      },
      onPanUpdate: (details) {
        setState(() {
          final newX = (_position!.dx + details.delta.dx).clamp(minX, maxX);
          var maxY = (size.height - 220).clamp(100.0, double.infinity).toDouble();
          final aboveSheet = _sheetMaxTop(size);
          if (aboveSheet < maxY) maxY = aboveSheet < 100.0 ? 100.0 : aboveSheet;
          final newY = (_position!.dy + details.delta.dy).clamp(100.0, maxY);
          _position = Offset(newX, newY);
        });
      },
      onPanEnd: (_) {
        // Magnetic snap to the nearest edge.
        HapticFeedback.lightImpact();
        final snapX = (_position!.dx < (widget.leftInset + size.width) / 2) ? leftEdge.clamp(minX, maxX).toDouble() : maxX;
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
            left: onLeft ? panelLeft : null,
            right: onLeft ? null : panelRight,
            width: panelW,
            top: ((_shownTop ?? _position!.dy) - 70).clamp(padding.top + 12, (size.height - 400).clamp(padding.top + 12, double.infinity)),
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
                isSolo: widget.isSolo,
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
        if (widget.sheetHeight == null && widget.sheetExpansion == null)
          Positioned(
            left: _position!.dx,
            top: _position!.dy,
            child: orbitFab,
          )
        else
          ListenableBuilder(
            listenable: Listenable.merge(<Listenable?>[widget.sheetHeight, widget.sheetExpansion]),
            builder: (context, _) => _sheetAwareFab(size, padding, orbitFab),
          ),
      ],
    );
  }

  /// Lowest top the button may have to stay clear of the ride sheet (and the
  /// controls riding on its edge); unbounded without a sheet.
  double _sheetMaxTop(Size size) {
    final sheet = widget.sheetHeight?.value ?? 0;
    if (sheet <= 0) return double.infinity;
    return size.height - sheet - widget.sheetClearance - _fabSize - 12;
  }

  /// The button kept above the ride sheet and faded out while the sheet is
  /// open (never while the rider is dragging it or its panel is open).
  Widget _sheetAwareFab(Size size, EdgeInsets padding, Widget fab) {
    var top = _position!.dy;
    final maxTop = _sheetMaxTop(size);
    if (top > maxTop) top = maxTop;
    final minTop = padding.top + 72;
    if (top < minTop) top = minTop;
    _shownTop = top;
    final t = widget.sheetExpansion?.value ?? 0;
    final opacity = (_isOpen || _isDragging) ? 1.0 : (1.0 - (t - 0.12) / 0.18).clamp(0.0, 1.0).toDouble();
    return Positioned(
      left: _position!.dx,
      top: top,
      child: IgnorePointer(
        ignoring: opacity < 0.5,
        child: Opacity(opacity: opacity, child: fab),
      ),
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
  final bool isSolo;

  const _OrbitQuickAccessCard({
    required this.onIntercomTap,
    required this.onGroupTap,
    required this.onFuelTap,
    required this.onRouteTap,
    required this.onGuardianTap,
    required this.onMoreTap,
    this.onSosTap,
    this.isSolo = false,
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
          if (isSolo) ...[
            Row(
              children: [
                Expanded(child: _OrbitTile(icon: Icons.local_gas_station_outlined, label: 'Fuel', onTap: onFuelTap)),
                const SizedBox(width: 10),
                Expanded(child: _OrbitTile(icon: Icons.route_outlined, label: 'Route', onTap: onRouteTap)),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(child: _OrbitTile(icon: Icons.verified_user_outlined, label: 'Guardian', onTap: onGuardianTap)),
                const SizedBox(width: 10),
                Expanded(child: _OrbitTile(icon: Icons.grid_view_rounded, label: 'More', onTap: onMoreTap)),
              ],
            ),
          ] else ...[
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
          ],
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
