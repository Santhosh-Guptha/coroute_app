import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_compass/flutter_compass.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:record/record.dart';
import '../../core/constants/app_constants.dart';
import '../../core/constants/telemetry_utils.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/cockpit_hud.dart';
import '../../core/widgets/glass_card.dart';
import '../../data/models/convoy_model.dart';
import '../../data/models/rider_model.dart';
import '../../data/models/trip_history_model.dart';
import '../../data/services/auth_service.dart';
import '../../data/services/convoy_service.dart';
import '../../data/services/trip_storage_service.dart';
import '../../data/services/oracle_ai_service.dart';

class LiveCockpitMapScreen extends StatefulWidget {
  final String convoyId;

  const LiveCockpitMapScreen({super.key, required this.convoyId});

  @override
  State<LiveCockpitMapScreen> createState() => _LiveCockpitMapScreenState();
}

class _LiveCockpitMapScreenState extends State<LiveCockpitMapScreen> {
  final MapController _mapController = MapController();
  bool _isPttPressed = false;
  bool _isMuted = false;
  bool _isDeafened = false;
  bool _autoFollow = true;
  bool _isVoxMode = false;
  bool _isVoxActive = false;

  final AudioRecorder _audioRecorder = AudioRecorder();
  final AudioPlayer _audioPlayer = AudioPlayer();
  StreamSubscription? _voiceBurstSub;
  String? _currentRecordingPath;
  DateTime? _pttStartTime;
  String? _incomingSpeakerName;
  Timer? _incomingSpeakerTimer;
  final Set<String> _dismissedAlertIds = {};
  StreamSubscription<CompassEvent>? _compassSub;
  double? _deviceCompassHeading;

  @override
  void initState() {
    super.initState();
    // Hardware compass orientation tracking (Mobile facing direction)
    _compassSub = FlutterCompass.events?.listen((CompassEvent event) {
      if (event.heading != null && mounted) {
        double h = event.heading!;
        if (h < 0) h += 360.0;
        setState(() {
          _deviceCompassHeading = h;
        });
      }
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      final convoyService = context.read<ConvoyService>();
      final authService = context.read<AuthService>();
      final myUserId = 'usr_${(authService.currentUserName ?? 'rider').toLowerCase().replaceAll(' ', '_')}';

      _voiceBurstSub = convoyService.voiceBurstStream.listen((burst) async {
        final senderId = burst['senderId']?.toString();
        final audioBase64 = burst['audioBase64']?.toString();
        final senderName = burst['senderName']?.toString() ?? 'Rider';

        if (senderId != myUserId && audioBase64 != null && audioBase64.isNotEmpty && !_isDeafened) {
          if (mounted) {
            setState(() {
              _incomingSpeakerName = senderName;
            });
            _incomingSpeakerTimer?.cancel();
            _incomingSpeakerTimer = Timer(const Duration(seconds: 4), () {
              if (mounted) setState(() => _incomingSpeakerName = null);
            });
          }
          try {
            final bytes = base64Decode(audioBase64);
            await _audioPlayer.stop();
            await _audioPlayer.play(BytesSource(bytes));
          } catch (e) {
            debugPrint('Cockpit playback error: $e');
          }
        }
      });
    });
  }

  @override
  void dispose() {
    _incomingSpeakerTimer?.cancel();
    _voiceBurstSub?.cancel();
    _compassSub?.cancel();
    _stopVoxLoop();
    _audioRecorder.dispose();
    _audioPlayer.dispose();
    super.dispose();
  }

  Future<void> _startRecording() async {
    if (_isMuted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Mic is muted. Unmute to transmit.'), duration: Duration(seconds: 1)),
      );
      return;
    }
    try {
      final hasPermission = await _audioRecorder.hasPermission();
      if (!hasPermission) return;

      HapticFeedback.heavyImpact();
      final tempDir = await getTemporaryDirectory();
      _currentRecordingPath = '${tempDir.path}/cockpit_${DateTime.now().millisecondsSinceEpoch}.m4a';
      _pttStartTime = DateTime.now();

      await _audioRecorder.start(
        const RecordConfig(
          encoder: AudioEncoder.aacLc,
          bitRate: 32000,
          sampleRate: 16000,
        ),
        path: _currentRecordingPath!,
      );

      if (mounted) setState(() => _isPttPressed = true);
    } catch (e) {
      debugPrint('Cockpit recording error: $e');
    }
  }

  Future<void> _stopRecordingAndBroadcast(RiderModel myRider, ConvoyService convoyService) async {
    if (!_isPttPressed && _currentRecordingPath == null) return;
    if (mounted) setState(() => _isPttPressed = false);

    try {
      if (await _audioRecorder.isRecording()) {
        final path = await _audioRecorder.stop();
        if (path != null && _pttStartTime != null) {
          final durationMs = DateTime.now().difference(_pttStartTime!).inMilliseconds;
          if (durationMs >= 300) {
            final file = File(path);
            if (await file.exists()) {
              final bytes = await file.readAsBytes();
              final base64Audio = base64Encode(bytes);
              convoyService.sendVoiceBurst(
                senderId: myRider.userId,
                senderName: myRider.name,
                audioBase64: base64Audio,
                durationMs: durationMs,
              ).ignore();
              file.delete().ignore();
            }
          }
        }
      }
    } catch (e) {
      debugPrint('Cockpit audio stop error: $e');
    }
  }

  Future<void> _startVoxLoop(RiderModel myRider, ConvoyService convoyService) async {
    if (_isVoxActive || _isMuted) return;
    if (mounted) setState(() => _isVoxActive = true);
    _runVoxCycle(myRider, convoyService);
  }

  Future<void> _runVoxCycle(RiderModel myRider, ConvoyService convoyService) async {
    if (!_isVoxActive || _isMuted || !mounted) return;

    try {
      final hasPermission = await _audioRecorder.hasPermission();
      if (!hasPermission) {
        if (mounted) setState(() => _isVoxActive = false);
        return;
      }

      final tempDir = await getTemporaryDirectory();
      final path = '${tempDir.path}/vox_cockpit_${DateTime.now().millisecondsSinceEpoch}.m4a';
      _currentRecordingPath = path;
      final startTime = DateTime.now();

      await _audioRecorder.start(
        const RecordConfig(
          encoder: AudioEncoder.aacLc,
          bitRate: 32000,
          sampleRate: 16000,
        ),
        path: path,
      );

      await Future.delayed(const Duration(milliseconds: 3200));

      if (!_isVoxActive || !mounted) {
        if (await _audioRecorder.isRecording()) {
          await _audioRecorder.stop();
        }
        return;
      }

      if (await _audioRecorder.isRecording()) {
        final savedPath = await _audioRecorder.stop();
        if (savedPath != null) {
          final file = File(savedPath);
          if (await file.exists()) {
            final durationMs = DateTime.now().difference(startTime).inMilliseconds;
            final bytes = await file.readAsBytes();
            if (bytes.length > 500) {
              final base64Audio = base64Encode(bytes);
              convoyService.sendVoiceBurst(
                senderId: myRider.userId,
                senderName: myRider.name,
                audioBase64: base64Audio,
                durationMs: durationMs,
              ).ignore();
            }
            file.delete().ignore();
          }
        }
      }
    } catch (e) {
      debugPrint('Cockpit VOX note: $e');
    }

    if (_isVoxActive && !_isMuted && mounted) {
      Future.delayed(const Duration(milliseconds: 150), () {
        if (_isVoxActive && !_isMuted && mounted) {
          _runVoxCycle(myRider, convoyService);
        }
      });
    }
  }

  void _stopVoxLoop() {
    _isVoxActive = false;
    _audioRecorder.isRecording().then((rec) {
      if (rec) _audioRecorder.stop();
    }).catchError((_) {});
  }

  /// 1. Riders List Modal: Details + Pan/Navigate to Rider on Map
  void _showRidersListModal(BuildContext context, ConvoyModel convoy, RiderModel myRider) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) {
        final riders = convoy.riders.values.toList();
        return Container(
          constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.7),
          decoration: const BoxDecoration(
            color: AppTheme.obsidianVoid,
            borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
            border: Border(top: BorderSide(color: AppTheme.neonCyan, width: 1.5)),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(bottom: 12),
                decoration: BoxDecoration(
                  color: AppTheme.textMuted,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    '🏍️ Convoy Pack (${riders.length} Riders)',
                    style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, color: AppTheme.textMuted, size: 20),
                    onPressed: () => Navigator.pop(ctx),
                  ),
                ],
              ),
              const Divider(color: AppTheme.glassBorder),
              Expanded(
                child: ListView.separated(
                  itemCount: riders.length,
                  separatorBuilder: (context, index) => const Divider(color: AppTheme.glassBorder, height: 1),
                  itemBuilder: (context, idx) {
                    final r = riders[idx];
                    final isMe = r.userId == myRider.userId || r.name == myRider.name;
                    final isOffline = !isMe && r.lastSeenEpochMs > 0 && (DateTime.now().millisecondsSinceEpoch - r.lastSeenEpochMs) > 60000;
                    final minutesAgo = isOffline ? ((DateTime.now().millisecondsSinceEpoch - r.lastSeenEpochMs) / 60000).round() : 0;
                    Color roleColor = isOffline ? AppTheme.hyperAmber : AppTheme.neonCyan;
                    if (!isOffline && r.role == 'LEAD') roleColor = AppTheme.hyperAmber;
                    if (!isOffline && r.role == 'SWEEPER') roleColor = AppTheme.electricBlue;

                    final distanceMeters = TelemetryUtils.calculateDistanceMeters(
                      LatLng(myRider.lat, myRider.lng),
                      LatLng(r.lat, r.lng),
                    );
                    final distText = distanceMeters > 1000
                        ? '${(distanceMeters / 1000.0).toStringAsFixed(1)} km away'
                        : '${distanceMeters.round()} m away';

                    return ListTile(
                      contentPadding: const EdgeInsets.symmetric(vertical: 4),
                      leading: Stack(
                        alignment: Alignment.bottomRight,
                        children: [
                          CircleAvatar(
                            backgroundColor: roleColor.withOpacity(0.2),
                            child: Text(
                              r.name.isNotEmpty ? r.name[0].toUpperCase() : 'R',
                              style: TextStyle(color: roleColor, fontWeight: FontWeight.bold),
                            ),
                          ),
                          Container(
                            width: 10,
                            height: 10,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: isOffline ? AppTheme.laserRed : (r.speedKmh > 1.5 ? AppTheme.emeraldSafe : AppTheme.hyperAmber),
                              border: Border.all(color: Colors.black, width: 1.5),
                            ),
                          ),
                        ],
                      ),
                      title: Row(
                        children: [
                          Flexible(
                            child: Text(
                              isMe ? '${r.name} (You)' : r.name,
                              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                            decoration: BoxDecoration(
                              color: roleColor.withOpacity(0.2),
                              borderRadius: BorderRadius.circular(4),
                              border: Border.all(color: roleColor, width: 0.8),
                            ),
                            child: Text(
                              isOffline ? 'OFFLINE' : r.role,
                              style: TextStyle(color: roleColor, fontSize: 9, fontWeight: FontWeight.bold),
                            ),
                          ),
                        ],
                      ),
                      subtitle: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Text(
                                isOffline ? 'Signal Lost' : '${r.speedKmh.round()} km/h',
                                style: TextStyle(color: isOffline ? AppTheme.laserRed : AppTheme.neonCyan, fontSize: 11, fontWeight: FontWeight.bold),
                              ),
                              const Text(' · ', style: TextStyle(color: AppTheme.textMuted)),
                              Icon(
                                r.isCharging ? Icons.battery_charging_full_rounded : Icons.battery_std_rounded,
                                size: 13,
                                color: r.batteryLevel < 20 ? AppTheme.laserRed : AppTheme.emeraldSafe,
                              ),
                              Text(
                                ' ${r.batteryLevel}%',
                                style: const TextStyle(color: AppTheme.textSecondary, fontSize: 11),
                              ),
                              if (!isMe && (r.lat != 0.0 || r.lng != 0.0)) ...[
                                const Text(' · ', style: TextStyle(color: AppTheme.textMuted)),
                                Text(
                                  distText,
                                  style: const TextStyle(color: AppTheme.textMuted, fontSize: 11),
                                ),
                              ],
                            ],
                          ),
                          if (isOffline)
                            Padding(
                              padding: const EdgeInsets.only(top: 2),
                              child: Text(
                                '⚠️ Last captured location · ${minutesAgo <= 1 ? "1m" : "${minutesAgo}m"} ago',
                                style: const TextStyle(color: AppTheme.hyperAmber, fontSize: 10, fontWeight: FontWeight.bold),
                              ),
                            ),
                        ],
                      ),
                      trailing: IconButton(
                        tooltip: isOffline ? 'Pan map to last known location' : 'Pan map to this rider',
                        icon: Icon(isOffline ? Icons.pin_drop_rounded : Icons.near_me_rounded, color: isOffline ? AppTheme.hyperAmber : AppTheme.neonCyan, size: 22),
                        onPressed: () {
                          if (r.lat != 0.0 && r.lng != 0.0) {
                            setState(() => _autoFollow = false);
                            _mapController.move(LatLng(r.lat, r.lng), 16.5);
                            Navigator.pop(ctx);
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text(isOffline ? 'Focused map on ${r.name}\'s last known location' : 'Focused map on ${r.name}')),
                            );
                          }
                        },
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  /// 2. In-Map Convoy Live Chat Modal: Read & Send without leaving map
  void _showChatModal(BuildContext context, ConvoyModel convoy, ConvoyService convoyService, RiderModel myRider) {
    final textCtrl = TextEditingController();
    final scrollCtrl = ScrollController();

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            final currentConvoy = convoyService.allConvoys[convoy.groupId] ?? convoy;
            final messages = currentConvoy.messages;

            return Padding(
              padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
              child: Container(
                constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.75),
                decoration: const BoxDecoration(
                  color: AppTheme.obsidianVoid,
                  borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
                  border: Border(top: BorderSide(color: AppTheme.neonCyan, width: 1.5)),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 40,
                      height: 4,
                      margin: const EdgeInsets.only(bottom: 8),
                      decoration: BoxDecoration(
                        color: AppTheme.textMuted,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          '💬 Convoy Live Chat (${messages.length})',
                          style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
                        ),
                        IconButton(
                          icon: const Icon(Icons.close, color: AppTheme.textMuted, size: 20),
                          onPressed: () => Navigator.pop(ctx),
                        ),
                      ],
                    ),
                    // Quick safety pills
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          {'emoji': '⛽', 'text': 'Need Fuel Stop'},
                          {'emoji': '☕', 'text': 'Tea / Rest Break'},
                          {'emoji': '⚠️', 'text': 'Road Hazard Ahead'},
                          {'emoji': '🛑', 'text': 'Regroup Here'},
                          {'emoji': '👍', 'text': 'All Good / Moving'},
                        ].map((q) {
                          return Padding(
                            padding: const EdgeInsets.only(right: 6, bottom: 8),
                            child: ActionChip(
                              backgroundColor: AppTheme.elevatedCard,
                              label: Text('${q['emoji']} ${q['text']}', style: const TextStyle(color: Colors.white, fontSize: 11)),
                              side: const BorderSide(color: AppTheme.glassBorder),
                              onPressed: () {
                                convoyService.sendGroupMessage(
                                  senderId: myRider.userId,
                                  senderName: myRider.name,
                                  text: '${q['emoji']} ${q['text']}',
                                  isQuickCard: true,
                                );
                                setModalState(() {});
                              },
                            ),
                          );
                        }).toList(),
                      ),
                    ),
                    const Divider(color: AppTheme.glassBorder, height: 1),
                    Expanded(
                      child: messages.isEmpty
                          ? const Center(
                              child: Text('No messages yet. Send a quick shout-out!', style: TextStyle(color: AppTheme.textMuted)),
                            )
                          : ListView.builder(
                              controller: scrollCtrl,
                              itemCount: messages.length,
                              itemBuilder: (context, i) {
                                final msg = messages[i];
                                final isMe = msg.senderId == myRider.userId || msg.senderName == myRider.name;
                                return Align(
                                  alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
                                  child: Container(
                                    margin: const EdgeInsets.symmetric(vertical: 4),
                                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                    decoration: BoxDecoration(
                                      color: isMe ? AppTheme.neonCyan.withOpacity(0.2) : AppTheme.slateCard,
                                      borderRadius: BorderRadius.circular(12),
                                      border: Border.all(
                                        color: isMe ? AppTheme.neonCyan.withOpacity(0.5) : AppTheme.glassBorder,
                                      ),
                                    ),
                                    child: Column(
                                      crossAxisAlignment: isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
                                      children: [
                                        if (!isMe)
                                          Text(
                                            msg.senderName,
                                            style: const TextStyle(color: AppTheme.neonCyan, fontSize: 10, fontWeight: FontWeight.bold),
                                          ),
                                        Text(
                                          msg.text,
                                          style: const TextStyle(color: Colors.white, fontSize: 13),
                                        ),
                                      ],
                                    ),
                                  ),
                                );
                              },
                            ),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: textCtrl,
                            style: const TextStyle(color: Colors.white, fontSize: 13),
                            decoration: InputDecoration(
                              hintText: 'Type a message to pack...',
                              hintStyle: const TextStyle(color: AppTheme.textMuted, fontSize: 12),
                              filled: true,
                              fillColor: AppTheme.elevatedCard,
                              contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(12),
                                borderSide: BorderSide.none,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        IconButton(
                          icon: const Icon(Icons.send_rounded, color: AppTheme.neonCyan),
                          onPressed: () {
                            final txt = textCtrl.text.trim();
                            if (txt.isNotEmpty) {
                              convoyService.sendGroupMessage(
                                senderId: myRider.userId,
                                senderName: myRider.name,
                                text: txt,
                              );
                              textCtrl.clear();
                              setModalState(() {});
                            }
                          },
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  /// 3. In-Map Route Checkpoints Modal: View & Add Stops
  void _showStopsModal(BuildContext context, ConvoyModel convoy, ConvoyService convoyService) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            final currentConvoy = convoyService.allConvoys[convoy.groupId] ?? convoy;
            final stops = currentConvoy.stopPoints;

            return Container(
              constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.7),
              decoration: const BoxDecoration(
                color: AppTheme.obsidianVoid,
                borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
                border: Border(top: BorderSide(color: AppTheme.hyperAmber, width: 1.5)),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 40,
                    height: 4,
                    margin: const EdgeInsets.only(bottom: 12),
                    decoration: BoxDecoration(
                      color: AppTheme.textMuted,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        '🛑 Route Checkpoints (${stops.length})',
                        style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close, color: AppTheme.textMuted, size: 20),
                        onPressed: () => Navigator.pop(ctx),
                      ),
                    ],
                  ),
                  const Divider(color: AppTheme.glassBorder),
                  Expanded(
                    child: stops.isEmpty
                        ? const Center(
                            child: Text('No planned stops added yet.', style: TextStyle(color: AppTheme.textMuted)),
                          )
                        : ListView.separated(
                            itemCount: stops.length,
                            separatorBuilder: (context, index) => const Divider(color: AppTheme.glassBorder, height: 1),
                            itemBuilder: (context, i) {
                              final s = stops[i];
                              return ListTile(
                                leading: Icon(
                                  s.isVisited ? Icons.check_circle_rounded : Icons.radio_button_unchecked_rounded,
                                  color: s.isVisited ? AppTheme.emeraldSafe : AppTheme.hyperAmber,
                                ),
                                title: Text(
                                  s.name,
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.bold,
                                    decoration: s.isVisited ? TextDecoration.lineThrough : null,
                                  ),
                                ),
                                subtitle: Text(
                                  'Category: ${s.category}',
                                  style: const TextStyle(color: AppTheme.textMuted, fontSize: 11),
                                ),
                                trailing: IconButton(
                                  icon: const Icon(Icons.near_me_rounded, color: AppTheme.neonCyan),
                                  onPressed: () {
                                    if (s.lat != 0.0 && s.lng != 0.0) {
                                      setState(() => _autoFollow = false);
                                      _mapController.move(LatLng(s.lat, s.lng), 16.0);
                                      Navigator.pop(ctx);
                                    }
                                  },
                                ),
                                onTap: () {
                                  convoyService.toggleStopVisited(s.stopId, !s.isVisited);
                                  setModalState(() {});
                                },
                              );
                            },
                          ),
                  ),
                  const SizedBox(height: 8),
                  ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppTheme.neonCyan,
                      foregroundColor: Colors.black,
                      minimumSize: const Size.fromHeight(44),
                    ),
                    icon: const Icon(Icons.add_location_alt_rounded),
                    label: const Text('Add Current GPS Location as Stop', style: TextStyle(fontWeight: FontWeight.bold)),
                    onPressed: () async {
                      try {
                        final pos = await Geolocator.getCurrentPosition();
                        convoyService.addStopPoint(
                          name: 'Checkpoint ${stops.length + 1}',
                          lat: pos.latitude,
                          lng: pos.longitude,
                          category: 'REST',
                        );
                        setModalState(() {});
                      } catch (_) {}
                    },
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  /// Map Floating Quick-Button Widget
  Widget _buildMapQuickButton({
    required IconData icon,
    required VoidCallback onTap,
    String? badgeText,
    Color badgeColor = AppTheme.neonCyan,
    required String tooltip,
  }) {
    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        onTap: onTap,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: AppTheme.obsidianVoid.withOpacity(0.85),
                shape: BoxShape.circle,
                border: Border.all(color: AppTheme.glassBorder, width: 1.2),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.4),
                    blurRadius: 8,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: Center(
                child: Icon(icon, color: Colors.white, size: 20),
              ),
            ),
            if (badgeText != null)
              Positioned(
                top: -3,
                right: -3,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                  decoration: BoxDecoration(
                    color: badgeColor,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: Colors.black, width: 1.2),
                  ),
                  child: Text(
                    badgeText,
                    style: const TextStyle(
                      color: Colors.black,
                      fontWeight: FontWeight.w900,
                      fontSize: 9,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  void _showEndTripDialog(BuildContext context, ConvoyModel convoy) {
    showDialog(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          backgroundColor: AppTheme.slateCard,
          title: const Text('Conclude Journey?', style: TextStyle(color: Colors.white)),
          content: Text(
            'This will complete the ride for "${convoy.name}" and save your full route and statistics to Trip History.',
            style: const TextStyle(color: AppTheme.textSecondary),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Keep Riding', style: TextStyle(color: AppTheme.textMuted)),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: AppTheme.hyperAmber),
              onPressed: () async {
                final tripStorage = context.read<TripStorageService>();
                final now = DateTime.now().millisecondsSinceEpoch;

                // Compute real trip stats from actual rider telemetry
                final allRiders = convoy.riders.values.toList();
                double topSpeed = 0.0;
                double totalSpeed = 0.0;
                int speedCount = 0;
                for (final r in allRiders) {
                  if (r.speedKmh > topSpeed) topSpeed = r.speedKmh;
                  totalSpeed += r.speedKmh;
                  speedCount++;
                }
                final avgSpeed = speedCount > 0 ? totalSpeed / speedCount : 0.0;

                // Estimate distance from ride duration and average speed
                final durationMs = now - convoy.createdAtEpochMs;
                final durationHours = durationMs / 3600000.0;
                final estimatedDistanceKm = avgSpeed * durationHours;

                final visitedStops = convoy.stopPoints.where((s) => s.isVisited).length;

                final history = TripHistoryModel(
                  tripId: 'TRIP-${DateTime.now().millisecondsSinceEpoch}',
                  tripName: convoy.name,
                  startLocationName: convoy.startLocationName.isNotEmpty ? convoy.startLocationName : 'Convoy Start',
                  destinationName: convoy.destinationName.isNotEmpty ? convoy.destinationName : 'Final Waypoint',
                  startTimeEpochMs: convoy.createdAtEpochMs,
                  endTimeEpochMs: now,
                  totalDistanceKm: double.parse(estimatedDistanceKm.toStringAsFixed(1)),
                  topSpeedKmh: double.parse(topSpeed.toStringAsFixed(1)),
                  avgSpeedKmh: double.parse(avgSpeed.toStringAsFixed(1)),
                  riderCount: convoy.riders.length,
                  stopCount: visitedStops,
                  breadcrumbTrail: allRiders.map((r) {
                    return TripBreadcrumbPoint(
                      lat: r.lat,
                      lng: r.lng,
                      speedKmh: r.speedKmh,
                      heading: r.heading,
                      timestamp: r.lastSeenEpochMs,
                    );
                  }).toList(),
                );

                final oracleService = context.read<OracleAiService>();
                await tripStorage.saveTrip(history);
                oracleService.saveTripToOracle(history);

                if (ctx.mounted) Navigator.pop(ctx);
                if (context.mounted) Navigator.pop(context);
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Journey saved locally & synced to Oracle 26ai Cloud!'),
                      backgroundColor: AppTheme.emeraldSafe,
                    ),
                  );
                }
              },
              child: const Text('Save & Finish', style: TextStyle(color: Colors.black)),
            ),
          ],
        );
      },
    );
  }

  void _triggerSos(BuildContext context, ConvoyService convoyService, AuthService auth) async {
    final currentUserName = auth.currentUserName ?? 'Rider';
    final myRider = convoyService.activeConvoy?.riders.values
        .where((r) => r.name.toLowerCase() == currentUserName.toLowerCase())
        .firstOrNull;

    double lat = myRider?.lat ?? 0.0;
    double lng = myRider?.lng ?? 0.0;

    // If rider has no valid position, get real GPS as fallback
    if (lat == 0.0 && lng == 0.0) {
      try {
        final pos = await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.high,
            timeLimit: Duration(seconds: 5),
          ),
        );
        lat = pos.latitude;
        lng = pos.longitude;
      } catch (_) {}
    }

    final myUserId = myRider?.userId ?? 'usr_${currentUserName.toLowerCase().replaceAll(' ', '_')}';

    convoyService.triggerSosAlert(
      userId: myUserId,
      userName: currentUserName,
      lat: lat,
      lng: lng,
    );

    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          backgroundColor: AppTheme.laserRed,
          content: Row(
            children: [
              Icon(Icons.warning, color: Colors.white),
              SizedBox(width: 8),
              Text('SOS Emergency Broadcasted to entire Convoy!'),
            ],
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthService>();
    final convoyService = context.watch<ConvoyService>();
    final convoy = convoyService.allConvoys[widget.convoyId];

    if (convoy == null) {
      return Scaffold(
        backgroundColor: AppTheme.obsidianVoid,
        appBar: AppBar(title: const Text('Convoy Concluded')),
        body: const Center(
          child: Text('This convoy has been dissolved or ended.', style: TextStyle(color: AppTheme.textMuted)),
        ),
      );
    }

    final riders = convoy.riders.values.toList();
    final metrics = TelemetryUtils.calculateConvoyMetrics(riders);

    // Current user rider reference
    final myRider = riders.firstWhere(
      (r) => r.name.toLowerCase() == (auth.currentUserName ?? '').toLowerCase(),
      orElse: () => riders.isNotEmpty ? riders.first : RiderModel(userId: '0', name: 'Rider', lat: 0.0, lng: 0.0, lastSeenEpochMs: 0),
    );

    return Scaffold(
      backgroundColor: AppTheme.obsidianVoid,
      body: Stack(
        children: [
          // 1. OpenStreetMap High-DPI Engine (100% Free, Zero Watermarks)
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: LatLng(myRider.lat, myRider.lng),
              initialZoom: 15.5,
              onPositionChanged: (pos, hasGesture) {
                if (hasGesture && _autoFollow) {
                  setState(() => _autoFollow = false);
                }
              },
            ),
            children: [
              TileLayer(
                urlTemplate: AppConstants.osmTileUrl,
                userAgentPackageName: AppConstants.osmUserAgent,
              ),

              // Rider Markers with Directional Rotating Chevrons
              MarkerLayer(
                markers: riders.where((r) => r.lat != 0.0 && r.lng != 0.0).map((r) {
                  final isMe = r.userId == myRider.userId || r.name.toLowerCase() == myRider.name.toLowerCase();
                  final isOffline = !isMe && r.lastSeenEpochMs > 0 && (DateTime.now().millisecondsSinceEpoch - r.lastSeenEpochMs) > 60000;
                  Color roleColor = isOffline ? AppTheme.hyperAmber : AppTheme.neonCyan;
                  if (!isOffline && r.role == 'LEAD') roleColor = AppTheme.hyperAmber;
                  if (!isOffline && r.role == 'SWEEPER') roleColor = AppTheme.electricBlue;

                  // Heading calculation with Compass Sensor Fusion
                  final effectiveHeading = isMe
                      ? ((r.speedKmh < 10.0 && _deviceCompassHeading != null) ? _deviceCompassHeading! : r.heading)
                      : r.heading;

                  return Marker(
                    point: LatLng(r.lat, r.lng),
                    width: 64,
                    height: 64,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // Rider name & speed tag
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                          decoration: BoxDecoration(
                            color: Colors.black.withOpacity(0.85),
                            borderRadius: BorderRadius.circular(4),
                            border: Border.all(color: (isOffline ? AppTheme.laserRed : roleColor).withOpacity(0.8), width: 0.8),
                          ),
                          child: Text(
                            isOffline
                                ? '${r.name.split(' ').first} · Last Known'
                                : '${isMe ? "You" : r.name.split(' ').first} · ${r.speedKmh.toStringAsFixed(0)}',
                            style: TextStyle(
                              color: isOffline ? AppTheme.hyperAmber : roleColor,
                              fontSize: 9,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        const SizedBox(height: 2),

                        // Directional Chevron Pointer / Last Location Marker
                        Transform.rotate(
                          angle: effectiveHeading * (math.pi / 180.0),
                          child: Container(
                            width: 32,
                            height: 32,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: isOffline ? AppTheme.hyperAmber : roleColor,
                              border: Border.all(color: Colors.black, width: 2.2),
                              boxShadow: [
                                BoxShadow(
                                  color: (isOffline ? AppTheme.laserRed : roleColor).withOpacity(0.5),
                                  blurRadius: 8,
                                  spreadRadius: 1,
                                ),
                              ],
                            ),
                            child: Center(
                              child: Icon(
                                isOffline ? Icons.pin_drop_rounded : Icons.navigation,
                                color: Colors.black,
                                size: 18,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  );
                }).toList(),
              ),
            ],
          ),

          // 2. Top Convoy Formation Status Bar
          Positioned(
            top: MediaQuery.of(context).padding.top + 8,
            left: 12,
            right: 12,
            child: Column(
              children: [
                // Global Emergency Safety Broadcast Banner (if active)
                if (convoyService.systemBroadcastMessage != null) ...[
                  Container(
                    margin: const EdgeInsets.only(bottom: 8),
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                    decoration: BoxDecoration(
                      color: AppTheme.laserRed,
                      borderRadius: BorderRadius.circular(12),
                      boxShadow: [
                        BoxShadow(
                          color: AppTheme.laserRed.withOpacity(0.4),
                          blurRadius: 10,
                        ),
                      ],
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.warning, color: Colors.white, size: 18),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            convoyService.systemBroadcastMessage!,
                            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],

                // Active SOS Emergency Alert Banner
                ...(() {
                  final currentUserName = auth.currentUserName ?? 'Rider';
                  final myUserId = 'usr_${currentUserName.toLowerCase().replaceAll(' ', '_')}';

                  // Active SOS alerts from current user (Self SOS - show status + cancel option, NO loud alarm)
                  final mySos = convoy.activeAlerts
                      .where((a) => !a.resolved &&
                          ((a.userId.isNotEmpty && (a.userId.toLowerCase() == myUserId.toLowerCase() || a.userId.toLowerCase() == (myRider.userId).toLowerCase())) ||
                           (a.userName.isNotEmpty && (a.userName.toLowerCase() == currentUserName.toLowerCase() || a.userName.toLowerCase() == myRider.name.toLowerCase()))))
                      .toList();

                  // Active SOS alerts from OTHER riders
                  final otherSos = convoy.activeAlerts
                      .where((a) => !a.resolved &&
                          !((a.userId.isNotEmpty && (a.userId.toLowerCase() == myUserId.toLowerCase() || a.userId.toLowerCase() == (myRider.userId).toLowerCase())) ||
                            (a.userName.isNotEmpty && (a.userName.toLowerCase() == currentUserName.toLowerCase() || a.userName.toLowerCase() == myRider.name.toLowerCase()))) &&
                          !_dismissedAlertIds.contains(a.alertId))
                      .toList();

                  final widgets = <Widget>[];

                  if (mySos.isNotEmpty) {
                    final alert = mySos.last;
                    widgets.add(
                      Container(
                        margin: const EdgeInsets.only(bottom: 8),
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                        decoration: BoxDecoration(
                          color: AppTheme.hyperAmber.withOpacity(0.95),
                          borderRadius: BorderRadius.circular(12),
                          boxShadow: [
                            BoxShadow(
                              color: AppTheme.hyperAmber.withOpacity(0.4),
                              blurRadius: 8,
                            ),
                          ],
                        ),
                        child: Row(
                          children: [
                            const Icon(Icons.emergency_share_rounded, color: Colors.black, size: 20),
                            const SizedBox(width: 8),
                            const Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    '🚨 YOUR SOS IS ACTIVE',
                                    style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold, fontSize: 12),
                                  ),
                                  Text(
                                    'Convoy members have your live coordinates',
                                    style: TextStyle(color: Colors.black87, fontSize: 10),
                                  ),
                                ],
                              ),
                            ),
                            ElevatedButton(
                              onPressed: () {
                                convoyService.resolveSosAlert(alert.alertId);
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(content: Text('Your SOS emergency has been cancelled.')),
                                );
                              },
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.black,
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                minimumSize: Size.zero,
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              ),
                              child: const Text('CANCEL SOS', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 10)),
                            ),
                          ],
                        ),
                      ),
                    );
                  }

                  if (otherSos.isNotEmpty) {
                    final lastSos = otherSos.last;
                    widgets.add(
                      Container(
                        margin: const EdgeInsets.only(bottom: 8),
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                        decoration: BoxDecoration(
                          color: AppTheme.laserRed,
                          borderRadius: BorderRadius.circular(12),
                          boxShadow: [
                            BoxShadow(
                              color: AppTheme.laserRed.withOpacity(0.5),
                              blurRadius: 10,
                              spreadRadius: 2,
                            ),
                          ],
                        ),
                        child: Row(
                          children: [
                            const Icon(Icons.warning_amber_rounded, color: Colors.white, size: 20),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    '🚨 SOS: ${lastSos.userName} NEEDS HELP!',
                                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12),
                                  ),
                                  Text(
                                    'Type: ${lastSos.alertType}',
                                    style: const TextStyle(color: Colors.white70, fontSize: 10),
                                  ),
                                ],
                              ),
                            ),
                            if (lastSos.lat != 0.0 && lastSos.lng != 0.0)
                              IconButton(
                                tooltip: 'Focus on Map',
                                icon: const Icon(Icons.location_searching, color: Colors.white, size: 18),
                                padding: EdgeInsets.zero,
                                constraints: const BoxConstraints(),
                                onPressed: () {
                                  setState(() => _autoFollow = false);
                                  _mapController.move(LatLng(lastSos.lat, lastSos.lng), 17.0);
                                },
                              ),
                            const SizedBox(width: 8),
                            IconButton(
                              tooltip: 'Acknowledge & Dismiss',
                              icon: const Icon(Icons.check_circle_outline, color: Colors.white, size: 20),
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(),
                              onPressed: () {
                                setState(() {
                                  _dismissedAlertIds.add(lastSos.alertId);
                                });
                                convoyService.resolveSosAlert(lastSos.alertId);
                              },
                            ),
                          ],
                        ),
                      ),
                    );
                  }

                  return widgets;
                })(),

                // Live Audio Speaker HUD Toast
                if (_incomingSpeakerName != null) ...[
                  Container(
                    margin: const EdgeInsets.only(bottom: 8),
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: AppTheme.neonCyan.withOpacity(0.25),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: AppTheme.neonCyan),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.volume_up_rounded, color: AppTheme.neonCyan, size: 16),
                        const SizedBox(width: 8),
                        Text(
                          '🔊 $_incomingSpeakerName is speaking...',
                          style: const TextStyle(color: AppTheme.neonCyan, fontSize: 12, fontWeight: FontWeight.bold),
                        ),
                      ],
                    ),
                  ),
                ],

                // Convoy Header Card
                GlassCard(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  child: Row(
                    children: [
                      IconButton(
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                        icon: const Icon(Icons.arrow_back, color: Colors.white, size: 20),
                        onPressed: () => Navigator.pop(context),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              convoy.name,
                              style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.bold,
                                fontSize: 14,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                            Text(
                              '${metrics.activeRiderCount} online · ${metrics.spreadKm.toStringAsFixed(1)} km spread · ${metrics.averageSpeedKmh.toStringAsFixed(0)} km/h avg',
                              style: const TextStyle(color: AppTheme.textSecondary, fontSize: 10),
                            ),
                          ],
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: Color(metrics.statusColor).withOpacity(0.2),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: Color(metrics.statusColor).withOpacity(0.6)),
                        ),
                        child: Text(
                          metrics.status,
                          style: TextStyle(
                            color: Color(metrics.statusColor),
                            fontWeight: FontWeight.bold,
                            fontSize: 10,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      IconButton(
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                        tooltip: 'End Ride',
                        icon: const Icon(Icons.flag_circle, color: AppTheme.hyperAmber, size: 22),
                        onPressed: () => _showEndTripDialog(context, convoy),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          // 3. Floating Glassmorphic Cockpit Telemetry HUD
          Positioned(
            top: MediaQuery.of(context).padding.top + 76,
            left: 12,
            child: CockpitHud(
              speedKmh: myRider.speedKmh,
              heading: (myRider.speedKmh < 10.0 && _deviceCompassHeading != null)
                  ? _deviceCompassHeading!
                  : myRider.heading,
              batteryLevel: myRider.batteryLevel,
              isCharging: myRider.isCharging,
            ),
          ),

          // 3b. Floating Quick-Action Buttons Column (Pack List, Live Chat, Stops/Checkpoints)
          Positioned(
            top: MediaQuery.of(context).padding.top + 76,
            right: 12,
            child: Column(
              children: [
                _buildMapQuickButton(
                  icon: Icons.two_wheeler_rounded,
                  badgeText: '${riders.length}',
                  badgeColor: AppTheme.neonCyan,
                  tooltip: 'Convoy Riders Pack',
                  onTap: () => _showRidersListModal(context, convoy, myRider),
                ),
                const SizedBox(height: 10),
                _buildMapQuickButton(
                  icon: Icons.chat_bubble_rounded,
                  badgeText: convoy.messages.isNotEmpty ? '${convoy.messages.length}' : null,
                  badgeColor: AppTheme.hyperAmber,
                  tooltip: 'Convoy Live Chat',
                  onTap: () => _showChatModal(context, convoy, convoyService, myRider),
                ),
                const SizedBox(height: 10),
                _buildMapQuickButton(
                  icon: Icons.flag_rounded,
                  badgeText: convoy.stopPoints.isNotEmpty ? '${convoy.stopPoints.length}' : null,
                  badgeColor: AppTheme.emeraldSafe,
                  tooltip: 'Route Checkpoints',
                  onTap: () => _showStopsModal(context, convoy, convoyService),
                ),
              ],
            ),
          ),

          // 4. Recenter FAB
          Positioned(
            right: 14,
            bottom: 120,
            child: FloatingActionButton.small(
              backgroundColor: AppTheme.slateCard,
              foregroundColor: _autoFollow ? AppTheme.neonCyan : AppTheme.textMuted,
              onPressed: () {
                setState(() => _autoFollow = true);
                _mapController.move(LatLng(myRider.lat, myRider.lng), 16.0);
              },
              child: const Icon(Icons.my_location),
            ),
          ),

          // 5. SOS Panic Emergency Button
          Positioned(
            left: 14,
            bottom: 120,
            child: FloatingActionButton(
              heroTag: 'sos_btn',
              backgroundColor: AppTheme.laserRed,
              foregroundColor: Colors.white,
              onPressed: () => _triggerSos(context, convoyService, auth),
              child: const Icon(Icons.sos, size: 28),
            ),
          ),

          // 6. Dual-Mode Voice Intercom Bottom Bar (PTT & Open-Mic VOX)
          Positioned(
            bottom: 20,
            left: 14,
            right: 14,
            child: GlassCard(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              backgroundColor: AppTheme.obsidianVoid.withOpacity(0.92),
              borderColor: (_isPttPressed || (_isVoxMode && !_isMuted))
                  ? AppTheme.neonCyan
                  : AppTheme.glassBorder,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Intercom Mode Toggle Bar: PTT vs VOX
                  Row(
                    children: [
                      Expanded(
                        child: InkWell(
                          borderRadius: BorderRadius.circular(8),
                          onTap: () {
                            setState(() {
                              _isVoxMode = false;
                              _stopVoxLoop();
                            });
                          },
                          child: Container(
                            padding: const EdgeInsets.symmetric(vertical: 5),
                            decoration: BoxDecoration(
                              color: !_isVoxMode
                                  ? AppTheme.neonCyan.withOpacity(0.2)
                                  : Colors.transparent,
                              borderRadius: BorderRadius.circular(8),
                              border: !_isVoxMode
                                  ? Border.all(color: AppTheme.neonCyan, width: 1.2)
                                  : null,
                            ),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(
                                  Icons.touch_app,
                                  size: 13,
                                  color: !_isVoxMode ? AppTheme.neonCyan : AppTheme.textMuted,
                                ),
                                const SizedBox(width: 4),
                                Text(
                                  'PTT (Hold to Talk)',
                                  style: TextStyle(
                                    color: !_isVoxMode ? AppTheme.neonCyan : AppTheme.textMuted,
                                    fontSize: 10,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: InkWell(
                          borderRadius: BorderRadius.circular(8),
                          onTap: () {
                            setState(() {
                              _isVoxMode = true;
                            });
                            if (!_isMuted) {
                              _startVoxLoop(myRider, convoyService);
                            }
                          },
                          child: Container(
                            padding: const EdgeInsets.symmetric(vertical: 5),
                            decoration: BoxDecoration(
                              color: _isVoxMode
                                  ? AppTheme.hyperAmber.withOpacity(0.2)
                                  : Colors.transparent,
                              borderRadius: BorderRadius.circular(8),
                              border: _isVoxMode
                                  ? Border.all(color: AppTheme.hyperAmber, width: 1.2)
                                  : null,
                            ),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(
                                  Icons.record_voice_over,
                                  size: 13,
                                  color: _isVoxMode ? AppTheme.hyperAmber : AppTheme.textMuted,
                                ),
                                const SizedBox(width: 4),
                                Text(
                                  'Open-Mic VOX (Hands-Free)',
                                  style: TextStyle(
                                    color: _isVoxMode ? AppTheme.hyperAmber : AppTheme.textMuted,
                                    fontSize: 10,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),

                  // Bottom Controls Row
                  Row(
                    children: [
                      // Mic Mute Button
                      IconButton(
                        icon: Icon(
                          _isMuted ? Icons.mic_off : Icons.mic,
                          color: _isMuted ? AppTheme.laserRed : AppTheme.neonCyan,
                        ),
                        onPressed: () {
                          setState(() {
                            _isMuted = !_isMuted;
                            if (_isMuted) {
                              _stopVoxLoop();
                            } else if (_isVoxMode) {
                              _startVoxLoop(myRider, convoyService);
                            }
                          });
                        },
                      ),

                      // Deafen Headset Button
                      IconButton(
                        icon: Icon(
                          _isDeafened ? Icons.volume_off : Icons.volume_up,
                          color: _isDeafened ? AppTheme.laserRed : Colors.white,
                        ),
                        onPressed: () => setState(() => _isDeafened = !_isDeafened),
                      ),

                      // Dual-Mode Action: PTT vs Open-Mic VOX
                      if (!_isVoxMode)
                        Expanded(
                          child: GestureDetector(
                            onTapDown: (_) => _startRecording(),
                            onTapUp: (_) => _stopRecordingAndBroadcast(myRider, convoyService),
                            onTapCancel: () => _stopRecordingAndBroadcast(myRider, convoyService),
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                              decoration: BoxDecoration(
                                gradient: LinearGradient(
                                  colors: _isPttPressed
                                      ? [AppTheme.emeraldSafe, AppTheme.neonCyan]
                                      : [AppTheme.slateCard, AppTheme.elevatedCard],
                                ),
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                  color: _isPttPressed ? AppTheme.emeraldSafe : AppTheme.subtleBorder,
                                ),
                              ),
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(
                                    Icons.mic,
                                    size: 16,
                                    color: _isPttPressed ? Colors.black : AppTheme.neonCyan,
                                  ),
                                  const SizedBox(width: 6),
                                  Text(
                                    _isPttPressed ? 'TRANSMITTING...' : 'HOLD TO TALK (PTT)',
                                    style: TextStyle(
                                      color: _isPttPressed ? Colors.black : Colors.white,
                                      fontWeight: FontWeight.bold,
                                      fontSize: 12,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        )
                      else
                        Expanded(
                          child: InkWell(
                            onTap: () {
                              setState(() {
                                _isMuted = !_isMuted;
                                if (_isMuted) {
                                  _stopVoxLoop();
                                } else {
                                  _startVoxLoop(myRider, convoyService);
                                }
                              });
                            },
                            borderRadius: BorderRadius.circular(12),
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                              decoration: BoxDecoration(
                                color: _isMuted
                                    ? AppTheme.hyperAmber.withOpacity(0.2)
                                    : AppTheme.emeraldSafe.withOpacity(0.25),
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                  color: _isMuted ? AppTheme.hyperAmber : AppTheme.emeraldSafe,
                                  width: 1.5,
                                ),
                              ),
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(
                                    _isMuted ? Icons.mic_off : Icons.graphic_eq,
                                    size: 16,
                                    color: _isMuted ? AppTheme.hyperAmber : AppTheme.emeraldSafe,
                                  ),
                                  const SizedBox(width: 6),
                                  Text(
                                    _isMuted
                                        ? 'VOX MUTED (Tap to Stream)'
                                        : '🗣️ OPEN-MIC ACTIVE (Hands-Free)',
                                    style: TextStyle(
                                      color: _isMuted ? AppTheme.hyperAmber : Colors.white,
                                      fontWeight: FontWeight.bold,
                                      fontSize: 11,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
