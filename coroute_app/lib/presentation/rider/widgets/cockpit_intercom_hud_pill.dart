import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../../../core/theme/app_theme.dart';
import '../../../data/services/audio_route_watchdog.dart';
import '../../../data/services/intercom_network_resilience.dart';
import '../../../data/services/intercom_service.dart';

/// A glove-friendly top HUD pill providing multi-modal visual intercom feedback,
/// animated active speaker waveforms, audio routing watchdog warnings with 1-tap recovery,
/// and tactical quick signals for degraded networks.
class CockpitIntercomHudPill extends StatefulWidget {
  final AudioRouteWatchdog? watchdog;
  final IntercomService? intercomService;
  final IntercomNetworkResilience? resilience;
  final Function(TacticalSignal)? onSendTacticalSignal;
  final VoidCallback? onReconnectBluetooth;
  final VoidCallback? onBoostVolume;
  final EdgeInsetsGeometry? margin;

  const CockpitIntercomHudPill({
    super.key,
    this.watchdog,
    this.intercomService,
    this.resilience,
    this.onSendTacticalSignal,
    this.onReconnectBluetooth,
    this.onBoostVolume,
    this.margin,
  });

  @override
  State<CockpitIntercomHudPill> createState() => _CockpitIntercomHudPillState();
}

class _CockpitIntercomHudPillState extends State<CockpitIntercomHudPill>
    with SingleTickerProviderStateMixin {
  late final AnimationController _waveController;
  bool _isShowingSheet = false;

  @override
  void initState() {
    super.initState();
    _waveController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );
  }

  @override
  void dispose() {
    _waveController.dispose();
    super.dispose();
  }

  void _showTacticalSignalsSheet(BuildContext context) {
    if (_isShowingSheet) return;
    _isShowingSheet = true;

    final screenSize = MediaQuery.sizeOf(context);

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      constraints: BoxConstraints(
        maxWidth: 600,
        maxHeight: screenSize.height * 0.88,
      ),
      backgroundColor: AppTheme.darkCanvas,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (ctx) => Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 600),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: SingleChildScrollView(
              physics: const BouncingScrollPhysics(),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.cell_tower, color: AppTheme.hyperAmber, size: 22),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'ZERO-BANDWIDTH QUICK SIGNALS',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: AppTheme.textPrimary,
                            fontSize: 14,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 1.0,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Transmits a 12-byte signal spoken aloud via TTS into teammates helmet headsets.',
                    style: TextStyle(color: AppTheme.textSecondary, fontSize: 12),
                  ),
                  const SizedBox(height: 16),
                  ...TacticalSignal.values.map((sig) {
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: SizedBox(
                        width: double.infinity,
                        height: 52,
                        child: ElevatedButton(
                          onPressed: () {
                            if (ctx.mounted) Navigator.pop(ctx);
                            widget.onSendTacticalSignal?.call(sig);
                            if (!context.mounted) return;
                            ScaffoldMessenger.of(context).clearSnackBars();
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text('Transmitted: ${sig.label}')),
                            );
                          },
                          style: ElevatedButton.styleFrom(
                            backgroundColor: AppTheme.elevatedCard,
                            foregroundColor: AppTheme.textPrimary,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                              side: BorderSide(color: AppTheme.subtleBorder),
                            ),
                          ),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  sig.label,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Icon(Icons.send_rounded, color: AppTheme.neonCyan, size: 18),
                            ],
                          ),
                        ),
                      ),
                    );
                  }),
                ],
              ),
            ),
          ),
        ),
      ),
    ).whenComplete(() {
      _isShowingSheet = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    AudioRouteWatchdog? wd = widget.watchdog;
    if (wd == null) {
      try {
        wd = Provider.of<AudioRouteWatchdog?>(context);
      } catch (_) {}
    }

    IntercomService? ic = widget.intercomService;
    if (ic == null) {
      try {
        ic = Provider.of<IntercomService?>(context);
      } catch (_) {}
    }

    final resilience = widget.resilience;

    final listenables = <Listenable>[];
    if (wd != null) {
      listenables.add(wd.healthNotifier);
      listenables.add(wd.activeSpeakerNotifier);
    }
    if (ic != null) {
      listenables.add(ic.activeSpeakerNotifier);
    }
    if (resilience != null) {
      listenables.add(resilience);
    }
    listenables.add(_waveController);

    return AnimatedBuilder(
      animation: Listenable.merge(listenables),
      builder: (context, _) {
        final health = wd?.healthNotifier.value ?? const AudioHealthState();
        final speaker = ic?.activeSpeakerNotifier.value ?? wd?.activeSpeakerNotifier.value;
        final lossRate = resilience?.currentLossRate ?? 0.0;

        if (speaker != null) {
          if (!_waveController.isAnimating) {
            _waveController.repeat();
          }
        } else {
          if (_waveController.isAnimating) {
            _waveController.stop();
          }
        }

        // 1. Audio Routing Issue: Helmet Bluetooth Disconnected or Volume Muted (0%)
        if (health.isAudioRoutingIssue) {
          final isBt = !health.isBluetoothConnected;
          final VoidCallback action = isBt
              ? () {
                  HapticFeedback.mediumImpact();
                  if (widget.onReconnectBluetooth != null) {
                    widget.onReconnectBluetooth!();
                  } else {
                    wd?.reconnectBluetooth();
                  }
                }
              : () {
                  HapticFeedback.mediumImpact();
                  if (widget.onBoostVolume != null) {
                    widget.onBoostVolume!();
                  } else {
                    wd?.boostIntercomVolume();
                  }
                };

          final labelText = isBt
              ? 'HELMET AUDIO DISCONNECTED · TAP TO RECONNECT'
              : 'INTERCOM MUTED (0%) · TAP TO BOOST';
          final actionText = isBt ? 'RECONNECT' : 'BOOST';
          final iconText = isBt ? '⚠️' : '🔇';

          return Semantics(
            container: true,
            button: true,
            liveRegion: true,
            label: labelText,
            child: Container(
              margin: widget.margin ?? const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              constraints: const BoxConstraints(minHeight: 52),
              decoration: BoxDecoration(
                color: AppTheme.laserRed.withOpacity(0.92),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: Colors.white.withOpacity(0.3), width: 1.5),
                boxShadow: [
                  BoxShadow(
                    color: AppTheme.laserRed.withOpacity(0.55),
                    blurRadius: 14,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: action,
                  borderRadius: BorderRadius.circular(16),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    child: Row(
                      children: [
                        Text(
                          iconText,
                          style: const TextStyle(fontSize: 18),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            labelText,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 0.6,
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 8),
                        GestureDetector(
                          onTap: action,
                          child: Container(
                            constraints: const BoxConstraints(minHeight: 48, minWidth: 48),
                            alignment: Alignment.center,
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                            decoration: BoxDecoration(
                              color: Colors.black.withOpacity(0.38),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: Colors.white.withOpacity(0.35)),
                            ),
                            child: Text(
                              actionText,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 11,
                                fontWeight: FontWeight.w900,
                                letterSpacing: 0.5,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          );
        }

        // 2. Active Speaker HUD Pill: Animated Waveform Bar [ 🎙️ Kiran speaking... ▰▰▱ ]
        if (speaker != null) {
          final isLead = speaker.isLead;
          final isEmergency = speaker.isEmergency;
          final Color accentColor = isEmergency
              ? AppTheme.laserRed
              : (isLead ? AppTheme.hyperAmber : AppTheme.neonCyan);

          final animVal = _waveController.value;
          final waveStep = (animVal * 3).floor() % 3;
          final waveUnicode = switch (waveStep) {
            0 => '▰▱▱',
            1 => '▰▰▱',
            _ => '▰▰▰',
          };

          final h1 = 8.0 + (animVal * 12.0);
          final h2 = 20.0 - (animVal * 10.0);
          final h3 = 10.0 + ((1.0 - animVal) * 10.0);

          return Semantics(
            container: true,
            liveRegion: true,
            label: '${speaker.speakerName} speaking on intercom',
            child: Container(
              margin: widget.margin ?? const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              constraints: const BoxConstraints(minHeight: 48),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: BoxDecoration(
                color: AppTheme.elevatedCard.withOpacity(0.96),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: accentColor, width: 2),
                boxShadow: [
                  BoxShadow(
                    color: accentColor.withOpacity(0.3),
                    blurRadius: 10,
                    offset: const Offset(0, 3),
                  ),
                ],
              ),
              child: Row(
                children: [
                  const Text(
                    '🎙️',
                    style: TextStyle(fontSize: 18),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Flexible(
                          child: Text(
                            '${speaker.speakerName} speaking...',
                            style: TextStyle(
                              color: AppTheme.textPrimary,
                              fontSize: 13,
                              fontWeight: FontWeight.w800,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          waveUnicode,
                          style: TextStyle(
                            color: accentColor,
                            fontSize: 13,
                            fontWeight: FontWeight.w900,
                            letterSpacing: 1.0,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  // Animated waveform visualizer bars
                  Row(
                    children: [
                      _WaveBar(height: h1, color: accentColor),
                      const SizedBox(width: 3),
                      _WaveBar(height: h2, color: accentColor),
                      const SizedBox(width: 3),
                      _WaveBar(height: h3, color: accentColor),
                    ],
                  ),
                ],
              ),
            ),
          );
        }

        // 3. Degraded Mountain Cellular Warning (> 20% loss)
        if (lossRate >= 0.20) {
          return Container(
            margin: widget.margin ?? const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: () => _showTacticalSignalsSheet(context),
                borderRadius: BorderRadius.circular(16),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  decoration: BoxDecoration(
                    color: AppTheme.hyperAmber.withOpacity(0.2),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: AppTheme.hyperAmber, width: 1.5),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.network_check, color: AppTheme.hyperAmber, size: 20),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'WEAK CELLULAR (${(lossRate * 100).round()}% LOSS) · TAP FOR QUICK SIGNALS',
                          style: TextStyle(
                            color: AppTheme.hyperAmber,
                            fontSize: 11,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 0.6,
                          ),
                        ),
                      ),
                      Icon(Icons.chevron_right, color: AppTheme.hyperAmber, size: 18),
                    ],
                  ),
                ),
              ),
            ),
          );
        }

        return const SizedBox.shrink();
      },
    );
  }
}

class _WaveBar extends StatelessWidget {
  final double height;
  final Color color;

  const _WaveBar({required this.height, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 3.5,
      height: height.clamp(4.0, 24.0),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(2),
      ),
    );
  }
}
