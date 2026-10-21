import 'package:flutter/material.dart';
import '../../data/models/convoy_model.dart';
import '../../domain/notify/notification_snapshot.dart';
import '../../domain/notify/status_text.dart';

/// In-App Convoy Bead Wire Widget.
///
/// Mirrors the horizontal lock-screen convoy bead chain:
/// [Ahead Node] ──(distance)── [YOU Node] ──(distance)── [Behind Node] ──(distance)── [Sweeper Node]
///
/// Displays real-time pack telemetry and optional glove-friendly action pills
/// ([ ⏸ WAIT ], [ 📍 MAP ], [ ⚠️ SOS ]).
class ConvoyBeadWireWidget extends StatelessWidget {
  final String convoyName;
  final ConvoyModel? convoy;
  final String? sweeperId;
  final List<RiderLine> ahead;
  final List<RiderLine> behind;
  final String? telemetry;
  final bool isLive;
  final bool showButtons;
  final VoidCallback? onWait;
  final VoidCallback? onMap;
  final VoidCallback? onSos;

  const ConvoyBeadWireWidget({
    super.key,
    required this.convoyName,
    this.convoy,
    this.sweeperId,
    this.ahead = const [],
    this.behind = const [],
    this.telemetry,
    this.isLive = true,
    this.showButtons = true,
    this.onWait,
    this.onMap,
    this.onSos,
  });

  /// Convenience constructor taking a [NotificationSnapshot].
  factory ConvoyBeadWireWidget.fromSnapshot({
    Key? key,
    required NotificationSnapshot snapshot,
    required String convoyName,
    ConvoyModel? convoy,
    String? sweeperId,
    bool isLive = true,
    bool showButtons = true,
    VoidCallback? onWait,
    VoidCallback? onMap,
    VoidCallback? onSos,
  }) {
    return ConvoyBeadWireWidget(
      key: key,
      convoyName: convoyName,
      convoy: convoy,
      sweeperId: sweeperId,
      ahead: snapshot.ahead,
      behind: snapshot.behind,
      telemetry: snapshot.telemetry,
      isLive: isLive,
      showButtons: showButtons,
      onWait: onWait,
      onMap: onMap,
      onSos: onSos,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    final aheadRider = ahead.firstOrNull;
    final behind1 = behind.isNotEmpty ? behind[0] : null;
    final behind2 = behind.length > 1 ? behind[1] : null;

    final packPos = ahead.length + 1;
    final totalRiders = ahead.length + behind.length + 1;
    final effectiveSweeperId = convoy?.sweeperId ?? sweeperId;
    bool isSweeper(RiderLine? r) =>
        r != null &&
        effectiveSweeperId != null &&
        effectiveSweeperId.isNotEmpty &&
        r.userId.isNotEmpty &&
        r.userId == effectiveSweeperId;

    return Container(
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1E293B) : const Color(0xFF0F172A),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: const Color(0xFF334155),
          width: 1,
        ),
        boxShadow: const [
          BoxShadow(
            color: Color(0x33000000),
            blurRadius: 10,
            offset: Offset(0, 4),
          ),
        ],
      ),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 1. Header: 🏍️ Convoy Name ... ● LIVE
          Row(
            children: [
              const Text(
                '🏍️ ',
                style: TextStyle(fontSize: 16),
              ),
              Expanded(
                child: Text(
                  convoyName.isNotEmpty ? convoyName : 'CoRoute Convoy',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 0.2,
                  ),
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                ),
              ),
              if (isLive)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: const Color(0xFF00E676).withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: const Color(0xFF00E676).withValues(alpha: 0.4),
                      width: 1,
                    ),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.circle, size: 7, color: Color(0xFF00E676)),
                      SizedBox(width: 4),
                      Text(
                        'LIVE',
                        style: TextStyle(
                          color: Color(0xFF00E676),
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 0.5,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),

          // 2. Horizontal Convoy Bead Chain (Ahead -> YOU -> Behind1 -> Behind2)
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              // Ahead Rider Node
              if (aheadRider != null) ...[
                _buildRiderNode(
                  name: aheadRider.name,
                  tag: aheadRider.flag ?? '▲ Ahead',
                  isYou: false,
                  isWarning: _isWarning(aheadRider.flag),
                  icon: Icons.two_wheeler,
                ),
                Expanded(
                  child: _buildConnector(
                    distText: StatusText.roundedDistance(aheadRider.distanceM),
                  ),
                ),
              ],

              // Central YOU Node
              _buildRiderNode(
                name: 'YOU',
                tag: 'Pack #$packPos',
                isYou: true,
                isWarning: false,
                icon: Icons.navigation,
              ),

              // Behind Rider 1
              if (behind1 != null) ...[
                Expanded(
                  child: _buildConnector(
                    distText: StatusText.roundedDistance(behind1.distanceM),
                  ),
                ),
                _buildRiderNode(
                  name: behind1.name,
                  tag: behind1.flag ?? (isSweeper(behind1) ? '▼ Sweeper' : '▼ Behind'),
                  isYou: false,
                  isWarning: _isWarning(behind1.flag),
                  icon: Icons.two_wheeler,
                ),
              ],

              // Behind Rider 2 / Sweeper
              if (behind2 != null) ...[
                Expanded(
                  child: _buildConnector(
                    distText: StatusText.roundedDistance(behind2.distanceM),
                  ),
                ),
                _buildRiderNode(
                  name: behind2.name,
                  tag: behind2.flag ?? (isSweeper(behind2) ? '▼ Sweeper' : '▼ Behind'),
                  isYou: false,
                  isWarning: _isWarning(behind2.flag),
                  icon: _isWarning(behind2.flag) ? Icons.warning_amber_rounded : Icons.two_wheeler,
                ),
              ],
            ],
          ),
          const SizedBox(height: 10),

          // 3. Telemetry Subtitle
          Text(
            telemetry ?? 'Pack #$packPos • $totalRiders riders',
            style: const TextStyle(
              color: Color(0xFF94A3B8),
              fontSize: 12,
              fontWeight: FontWeight.w500,
            ),
          ),

          // 4. Glove-Friendly Action Buttons: [ ⏸ WAIT ]  [ 📍 MAP ]  [ ⚠️ SOS ]
          if (showButtons) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: _buildPillButton(
                    label: '⏸  WAIT',
                    color: const Color(0xFF334155),
                    textColor: Colors.white,
                    onTap: onWait,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _buildPillButton(
                    label: '📍  MAP',
                    color: const Color(0xFF334155),
                    textColor: Colors.white,
                    onTap: onMap,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _buildPillButton(
                    label: '⚠️  SOS',
                    color: const Color(0xFF7F1D1D),
                    borderColor: const Color(0xFFEF4444),
                    textColor: const Color(0xFFFCA5A5),
                    onTap: onSos,
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  bool _isWarning(String? flag) {
    if (flag == null) return false;
    final lower = flag.toLowerCase();
    return lower.contains('stop') || lower.contains('signal') || lower.contains('offline');
  }

  Widget _buildRiderNode({
    required String name,
    required String tag,
    required bool isYou,
    required bool isWarning,
    required IconData icon,
  }) {
    final Color ringColor;
    final Color bgColor;
    final Color tagColor;

    if (isYou) {
      ringColor = const Color(0xFF00E676);
      bgColor = const Color(0xFF00E676).withValues(alpha: 0.2);
      tagColor = const Color(0xFF00E676);
    } else if (isWarning) {
      ringColor = const Color(0xFFFF9100);
      bgColor = const Color(0xFFFF9100).withValues(alpha: 0.2);
      tagColor = const Color(0xFFFF9100);
    } else {
      ringColor = const Color(0xFF38BDF8);
      bgColor = const Color(0xFF38BDF8).withValues(alpha: 0.2);
      tagColor = const Color(0xFF94A3B8);
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Name
        SizedBox(
          width: 58,
          child: Text(
            name,
            style: TextStyle(
              color: isYou ? const Color(0xFF00E676) : const Color(0xFFE2E8F0),
              fontSize: 11,
              fontWeight: isYou ? FontWeight.bold : FontWeight.w500,
            ),
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        const SizedBox(height: 4),

        // Circle Badge
        Container(
          width: isYou ? 36 : 30,
          height: isYou ? 36 : 30,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: bgColor,
            border: Border.all(
              color: ringColor,
              width: isYou ? 2.5 : 1.5,
            ),
            boxShadow: isYou
                ? [
                    BoxShadow(
                      color: const Color(0xFF00E676).withValues(alpha: 0.4),
                      blurRadius: 8,
                      spreadRadius: 1,
                    )
                  ]
                : null,
          ),
          child: Center(
            child: Icon(
              icon,
              size: isYou ? 18 : 15,
              color: ringColor,
            ),
          ),
        ),
        const SizedBox(height: 4),

        // Tag
        SizedBox(
          width: 60,
          child: Text(
            tag,
            style: TextStyle(
              color: tagColor,
              fontSize: 9,
              fontWeight: FontWeight.w600,
            ),
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }

  Widget _buildConnector({required String distText}) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: Stack(
        alignment: Alignment.center,
        children: [
          // Dashed / solid connector wire
          Container(
            height: 2,
            color: const Color(0xFF475569),
          ),

          // Distance Pill
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: const Color(0xFF0F172A),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: const Color(0xFF475569),
                width: 1,
              ),
            ),
            child: Text(
              distText,
              style: const TextStyle(
                color: Color(0xFFCBD5E1),
                fontSize: 9,
                fontWeight: FontWeight.bold,
              ),
              maxLines: 1,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPillButton({
    required String label,
    required Color color,
    Color? borderColor,
    required Color textColor,
    VoidCallback? onTap,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(22),
        child: Ink(
          height: 42,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(22),
            border: borderColor != null
                ? Border.all(color: borderColor, width: 1.5)
                : null,
          ),
          child: Center(
            child: Text(
              label,
              style: TextStyle(
                color: textColor,
                fontSize: 12,
                fontWeight: FontWeight.bold,
                letterSpacing: 0.5,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
