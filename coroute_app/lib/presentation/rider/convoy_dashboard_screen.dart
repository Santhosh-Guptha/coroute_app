import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
import '../../core/config/app_config.dart';
import '../../core/constants/telemetry_utils.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/glass_card.dart';
import '../../data/models/convoy_model.dart';
import '../../data/models/rider_model.dart';
import '../../data/services/auth_service.dart';
import '../../data/services/convoy_service.dart';
import '../widgets/connection_banner.dart';
import '../widgets/intercom_dock.dart';
import 'live_cockpit_map_screen.dart';
import '../timeline/live_timeline_screen.dart';
import '../trip_planner/route_stops_panel.dart';

class ConvoyDashboardScreen extends StatefulWidget {
  final String groupId;

  const ConvoyDashboardScreen({super.key, required this.groupId});

  @override
  State<ConvoyDashboardScreen> createState() => _ConvoyDashboardScreenState();
}

class _ConvoyDashboardScreenState extends State<ConvoyDashboardScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final _messageController = TextEditingController();
  final _scrollController = ScrollController();

  bool _isFocusMode = false;
  final Set<String> _dismissedAlertIds = {};

  Timer? _waitCountdownTimer;
  int _waitRemainingSeconds = 0;
  String? _waitRequesterName;

  final List<Map<String, String>> _statusReasons = [
    {'code': 'FUELING', 'label': 'Fueling', 'emoji': '⛽'},
    {'code': 'REST_BREAK', 'label': 'Rest Break', 'emoji': '☕'},
    {'code': 'MECHANICAL', 'label': 'Mechanical Issue', 'emoji': '🔧'},
    {'code': 'FLAT_TIRE', 'label': 'Flat Tire', 'emoji': '🛞'},
    {'code': 'TRAFFIC', 'label': 'Traffic Delay', 'emoji': '🚦'},
    {'code': 'RAIN_DELAY', 'label': 'Rain Delay', 'emoji': '🌧️'},
    {'code': 'PHOTO_STOP', 'label': 'Photo Stop', 'emoji': '📸'},
    {'code': 'MEDICAL', 'label': 'Medical Emergency', 'emoji': '🏥'},
    {'code': 'REGROUP', 'label': 'Regroup Wait', 'emoji': '🛑'},
    {'code': 'CUSTOM', 'label': 'Custom Reason', 'emoji': '💬'},
  ];

  Map<String, String> _getStatusInfo(String code) {
    return _statusReasons.firstWhere(
      (r) => r['code'] == code,
      orElse: () => {'code': code, 'label': code, 'emoji': '⚠️'},
    );
  }

  void _showCustomReasonDialog(BuildContext context, ConvoyService convoyService, String userId) {
    final customCtrl = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.slateCard,
        title: const Text('💬 Custom Stop Reason', style: TextStyle(color: Colors.white, fontSize: 16)),
        content: TextField(
          controller: customCtrl,
          autofocus: true,
          style: const TextStyle(color: Colors.white),
          decoration: InputDecoration(
            hintText: 'e.g. ATM withdrawal, adjusting gear...',
            hintStyle: const TextStyle(color: AppTheme.textMuted),
            filled: true,
            fillColor: AppTheme.elevatedCard,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel', style: TextStyle(color: AppTheme.textMuted)),
          ),
          ElevatedButton(
            onPressed: () {
              final text = customCtrl.text.trim();
              if (text.isNotEmpty) {
                convoyService.updateStatusReason(
                  userId: userId,
                  reason: 'CUSTOM',
                  message: text,
                );
              }
              Navigator.pop(ctx);
            },
            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.neonCyan),
            child: const Text('Set Status', style: TextStyle(color: Colors.black)),
          ),
        ],
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 4, vsync: this);
  }

  @override
  void dispose() {
    _waitCountdownTimer?.cancel();
    _tabController.dispose();
    _messageController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _checkWaitRequests(ConvoyModel convoy) {
    if (convoy.waitRequests.isEmpty) {
      if (_waitRemainingSeconds > 0) {
        setState(() {
          _waitRemainingSeconds = 0;
          _waitRequesterName = null;
        });
        _waitCountdownTimer?.cancel();
      }
      return;
    }

    final now = DateTime.now().millisecondsSinceEpoch;
    // Find the newest request within 120 seconds
    String? newestRequester;
    int newestTime = 0;
    convoy.waitRequests.forEach((name, time) {
      if (now - time < 120000 && time > newestTime) {
        newestTime = time;
        newestRequester = name;
      }
    });

    if (newestRequester != null) {
      final elapsed = (now - newestTime) ~/ 1000;
      final remaining = (120 - elapsed).clamp(0, 120);

      if (remaining > 0 && _waitRemainingSeconds == 0) {
        setState(() {
          _waitRemainingSeconds = remaining;
          _waitRequesterName = newestRequester;
        });

        _waitCountdownTimer?.cancel();
        _waitCountdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
          if (_waitRemainingSeconds <= 1) {
            timer.cancel();
            setState(() {
              _waitRemainingSeconds = 0;
              _waitRequesterName = null;
            });
          } else {
            setState(() => _waitRemainingSeconds--);
          }
        });
      }
    }
  }

  void _showMemberProfileDialog(BuildContext context, RiderModel member, ConvoyService convoyService, String currentUserId) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.slateCard,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                color: AppTheme.neonCyan,
              ),
              child: const Icon(Icons.two_wheeler_rounded, color: Colors.black, size: 20),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(member.name, style: const TextStyle(color: Colors.white, fontSize: 16)),
                  Text(member.vehicleType, style: const TextStyle(color: AppTheme.textSecondary, fontSize: 12)),
                ],
              ),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (member.vehicleNo.isNotEmpty) ...[
              _buildProfileRow(Icons.pin_outlined, 'Vehicle No', member.vehicleNo),
              const Divider(color: AppTheme.glassBorder),
            ],
            if (member.phone.isNotEmpty) ...[
              _buildProfileRow(Icons.phone_outlined, 'Rider Contact', member.phone),
              const Divider(color: AppTheme.glassBorder),
            ],
            if (member.emergencyContact.isNotEmpty) ...[
              _buildProfileRow(
                Icons.emergency_outlined,
                'Emergency SOS Contact',
                '${member.emergencyContactName.isNotEmpty ? "${member.emergencyContactName} - " : ""}${member.emergencyContact}',
              ),
              const Divider(color: AppTheme.glassBorder),
            ],
            _buildProfileRow(Icons.speed_rounded, 'Speed & Heading', '${member.speedKmh.round()} km/h · ${TelemetryUtils.formatHeading(member.heading)}'),
            const SizedBox(height: 6),
            _buildProfileRow(Icons.battery_std_rounded, 'Battery Level', '${member.batteryLevel}%${member.isCharging ? " (Charging)" : ""}'),

            if (member.userId != currentUserId) ...[
              const SizedBox(height: 16),
              OutlinedButton.icon(
                onPressed: () {
                  convoyService.setCoRiderDriver(currentUserId, member.userId);
                  Navigator.pop(ctx);
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Paired with driver ${member.name} as pillion rider!')),
                  );
                },
                icon: const Icon(Icons.link_rounded, color: AppTheme.neonCyan, size: 16),
                label: const Text('Pair as Pillion (Driver Separation Alert)', style: TextStyle(color: AppTheme.neonCyan, fontSize: 12)),
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close', style: TextStyle(color: AppTheme.neonCyan)),
          ),
        ],
      ),
    );
  }

  Widget _buildProfileRow(IconData icon, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(icon, color: AppTheme.neonCyan, size: 16),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: const TextStyle(color: AppTheme.textMuted, fontSize: 10)),
                Text(value, style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final convoyService = context.watch<ConvoyService>();
    final authService = context.watch<AuthService>();
    final convoy = convoyService.allConvoys[widget.groupId] ?? convoyService.activeConvoy;

    if (convoy == null) {
      return Scaffold(
        backgroundColor: AppTheme.obsidianVoid,
        appBar: AppBar(title: const Text('Convoy Dashboard')),
        body: const Center(
          child: Text('Convoy session not found or concluded.', style: TextStyle(color: Colors.white)),
        ),
      );
    }

    _checkWaitRequests(convoy);
    if (convoyService.sosRequestedFromNotification) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        convoyService.clearSosRequest();
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('SOS sent to your convoy from the notification. Resolve it below when you are safe.'),
          backgroundColor: AppTheme.laserRed,
          duration: Duration(seconds: 5),
        ));
      });
    }

    final currentUserId = authService.currentUserId ?? convoyService.myUserId ?? '';
    final currentRider = convoy.riders[currentUserId] ??
        RiderModel(
          userId: currentUserId,
          name: authService.currentUserName ?? 'You',
          vehicleType: authService.vehicleType ?? 'Motorcycle',
          lat: 0.0,
          lng: 0.0,
          lastSeenEpochMs: DateTime.now().millisecondsSinceEpoch,
        );

    final isCreator = convoy.createdByUserId == currentUserId;

    // Check active SOS alerts from other members (excluding self, resolved, and locally dismissed alerts)
    final otherSosAlerts = convoy.activeAlerts
        .where((a) => a.userId != currentUserId && !a.resolved && !_dismissedAlertIds.contains(a.alertId))
        .toList();

    // Check if the current user themselves has an active broadcasted SOS
    final myActiveSosAlerts = convoy.activeAlerts.where((a) => a.userId == currentUserId && !a.resolved).toList();

    return Scaffold(
      backgroundColor: AppTheme.obsidianVoid,
      appBar: AppBar(
        backgroundColor: AppTheme.slateCard,
        elevation: 0,
        titleSpacing: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded, color: Colors.white),
          onPressed: () => Navigator.pop(context),
        ),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Flexible(
                  child: Text(
                    convoy.name,
                    style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: convoy.tripStatus == 'STARTED'
                        ? AppTheme.emeraldSafe.withOpacity(0.2)
                        : AppTheme.hyperAmber.withOpacity(0.2),
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(
                      color: convoy.tripStatus == 'STARTED'
                          ? AppTheme.emeraldSafe
                          : AppTheme.hyperAmber,
                    ),
                  ),
                  child: Text(
                    convoy.tripStatus,
                    style: TextStyle(
                      color: convoy.tripStatus == 'STARTED'
                          ? AppTheme.emeraldSafe
                          : AppTheme.hyperAmber,
                      fontSize: 9,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
            Row(
              children: [
                Text(
                  'CODE: ${convoy.joinCode}',
                  style: const TextStyle(color: AppTheme.neonCyan, fontSize: 11, fontWeight: FontWeight.bold, letterSpacing: 0.8),
                ),
                IconButton(
                  icon: const Icon(Icons.copy_rounded, color: AppTheme.neonCyan, size: 13),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: convoy.joinCode));
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Convoy Code ${convoy.joinCode} copied!')),
                    );
                  },
                ),
                IconButton(
                  tooltip: 'Share invite link',
                  icon: const Icon(Icons.share_rounded, color: AppTheme.neonCyan, size: 13),
                  padding: const EdgeInsets.only(left: 6),
                  constraints: const BoxConstraints(),
                  onPressed: () {
                    final link = '${AppConfig.apiBaseUrl}/join/${convoy.joinCode}';
                    SharePlus.instance.share(ShareParams(
                      text: 'Join my CoRoute convoy "${convoy.name}". Code ${convoy.joinCode}. Tap to open: $link',
                      subject: 'CoRoute convoy: ${convoy.name}',
                    ));
                  },
                ),
              ],
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: Icon(
              _isFocusMode ? Icons.fullscreen_exit_rounded : Icons.fullscreen_rounded,
              color: _isFocusMode ? AppTheme.hyperAmber : Colors.white,
            ),
            tooltip: 'Riding Focus Mode',
            onPressed: () => setState(() => _isFocusMode = !_isFocusMode),
          ),
          IconButton(
            icon: const Icon(Icons.timeline_rounded, color: AppTheme.neonCyan),
            tooltip: 'Group timeline',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => LiveTimelineScreen(groupId: convoy.groupId)),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.map_rounded, color: AppTheme.neonCyan),
            tooltip: 'Live Cockpit Map',
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => LiveCockpitMapScreen(convoyId: convoy.groupId),
                ),
              );
            },
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert_rounded, color: Colors.white),
            color: AppTheme.elevatedCard,
            onSelected: (val) {
              if (val == 'leave') {
                convoyService.leaveActiveConvoy(currentUserId);
                Navigator.pop(context);
              }
            },
            itemBuilder: (ctx) => [
              const PopupMenuItem(
                value: 'leave',
                child: Row(
                  children: [
                    Icon(Icons.exit_to_app_rounded, color: AppTheme.laserRed, size: 18),
                    SizedBox(width: 8),
                    Text('Leave Convoy', style: TextStyle(color: AppTheme.laserRed, fontSize: 13)),
                  ],
                ),
              ),
            ],
          ),
        ],
        bottom: TabBar(
          controller: _tabController,
          indicatorColor: AppTheme.neonCyan,
          labelColor: AppTheme.neonCyan,
          unselectedLabelColor: AppTheme.textSecondary,
          labelStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
          tabs: [
            Tab(text: 'Riders (${convoy.riders.length})'),
            Tab(text: 'Chat (${convoy.messages.length})'),
            Tab(text: 'Stops (${convoy.stopPoints.length})'),
            const Tab(text: '⚙️ Settings'),
          ],
        ),
      ),
      body: Column(
        children: [
          const ConnectionBanner(),
          // 1. 2-Minute Pull-Over Wait Timer Alert Banner
          if (_waitRemainingSeconds > 0)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              color: AppTheme.hyperAmber,
              child: Row(
                children: [
                  const Icon(Icons.hourglass_top_rounded, color: Colors.black, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'PULL-OVER STOP REQUESTED by ${_waitRequesterName ?? "Rider"}: ${_waitRemainingSeconds ~/ 60}:${(_waitRemainingSeconds % 60).toString().padLeft(2, "0")}',
                      style: const TextStyle(color: Colors.black, fontWeight: FontWeight.bold, fontSize: 12),
                    ),
                  ),
                ],
              ),
            ),

          // Self Active SOS Alert Notice (No alarm, just status & cancel action)
          if (myActiveSosAlerts.isNotEmpty)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              color: AppTheme.hyperAmber.withOpacity(0.95),
              child: Row(
                children: [
                  const Icon(Icons.emergency_share_rounded, color: Colors.black, size: 22),
                  const SizedBox(width: 10),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '🚨 YOUR SOS IS ACTIVE',
                          style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold, fontSize: 13),
                        ),
                        Text(
                          'Convoy members have your live coordinates',
                          style: TextStyle(color: Colors.black87, fontSize: 11),
                        ),
                      ],
                    ),
                  ),
                  ElevatedButton(
                    onPressed: () {
                      final alertId = myActiveSosAlerts.last.alertId;
                      convoyService.resolveSosAlert(alertId);
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Your SOS emergency alert has been cancelled.')),
                      );
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.black,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    ),
                    child: const Text('CANCEL SOS', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11)),
                  ),
                ],
              ),
            ),

          // 2. SOS Emergency Flash Banner
          if (otherSosAlerts.isNotEmpty)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              color: AppTheme.laserRed,
              child: Row(
                children: [
                  const Icon(Icons.warning_amber_rounded, color: Colors.white, size: 22),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '🚨 SOS: ${otherSosAlerts.last.userName} NEEDS HELP!',
                          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13),
                        ),
                        Text(
                          'Emergency Type: ${otherSosAlerts.last.alertType}',
                          style: const TextStyle(color: Colors.white70, fontSize: 11),
                        ),
                      ],
                    ),
                  ),
                  ElevatedButton(
                    onPressed: () {
                      final alertId = otherSosAlerts.last.alertId;
                      setState(() {
                        _dismissedAlertIds.add(alertId);
                      });
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => LiveCockpitMapScreen(convoyId: convoy.groupId),
                        ),
                      );
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.white,
                      foregroundColor: AppTheme.laserRed,
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    ),
                    child: const Text('NAVIGATE', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11)),
                  ),
                  IconButton(
                    icon: const Icon(Icons.check_circle_outline, color: Colors.white, size: 20),
                    tooltip: 'Acknowledge & Dismiss Alert',
                    onPressed: () {
                      final alertId = otherSosAlerts.last.alertId;
                      setState(() {
                        _dismissedAlertIds.add(alertId);
                      });
                      convoyService.resolveSosAlert(alertId);
                    },
                  ),
                ],
              ),
            ),

          // 3. Stopped Rider Prompt (If current rider stopped for long)
          if (currentRider.speedKmh < 1.5 && currentRider.statusReason.isEmpty)
            Container(
              margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: AppTheme.hyperAmber.withOpacity(0.12),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: AppTheme.hyperAmber.withOpacity(0.4)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '🛑 You are stopped. Let your convoy know why:',
                    style: TextStyle(color: AppTheme.hyperAmber, fontSize: 12, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 6),
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: _statusReasons.map((r) {
                        return Padding(
                          padding: const EdgeInsets.only(right: 6),
                          child: ActionChip(
                            avatar: Text(r['emoji']!),
                            label: Text(r['label']!, style: const TextStyle(fontSize: 11, color: Colors.white)),
                            backgroundColor: AppTheme.elevatedCard,
                            side: const BorderSide(color: AppTheme.glassBorder),
                            onPressed: () {
                              if (r['code'] == 'CUSTOM') {
                                _showCustomReasonDialog(context, convoyService, currentRider.userId);
                              } else {
                                convoyService.updateStatusReason(
                                  userId: currentRider.userId,
                                  reason: r['code']!,
                                );
                              }
                            },
                          ),
                        );
                      }).toList(),
                    ),
                  ),
                ],
              ),
            ),

          // 3b. Active Status Banner (If current rider has an active reason)
          if (currentRider.statusReason.isNotEmpty)
            Container(
              margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: currentRider.statusReason == 'MEDICAL'
                    ? AppTheme.laserRed.withOpacity(0.2)
                    : AppTheme.hyperAmber.withOpacity(0.18),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: currentRider.statusReason == 'MEDICAL'
                      ? AppTheme.laserRed
                      : AppTheme.hyperAmber,
                ),
              ),
              child: Row(
                children: [
                  Text(_getStatusInfo(currentRider.statusReason)['emoji'] ?? '⚠️', style: const TextStyle(fontSize: 16)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Your Status: ${_getStatusInfo(currentRider.statusReason)['label']}${currentRider.statusMessage.isNotEmpty ? " (${currentRider.statusMessage})" : ""}',
                      style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold),
                    ),
                  ),
                  TextButton.icon(
                    onPressed: () {
                      convoyService.updateStatusReason(
                        userId: currentRider.userId,
                        reason: '',
                      );
                    },
                    icon: const Icon(Icons.check_circle_outline, size: 16, color: AppTheme.emeraldSafe),
                    label: const Text('Clear', style: TextStyle(color: AppTheme.emeraldSafe, fontSize: 12)),
                  ),
                ],
              ),
            ),

          // 4. Tab Views
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: [
                // TAB 0: RIDERS LIST (WITH AHEAD / BEHIND)
                _buildRidersTab(convoy, currentRider, isCreator, convoyService),

                // TAB 1: CHAT & QUICK COMMS
                _buildChatTab(convoy, currentRider, convoyService),

                // TAB 2: STOPS & CHECKPOINTS
                _buildStopsTab(convoy, isCreator, convoyService),

                // TAB 3: SETTINGS
                _buildSettingsTab(convoy, isCreator, convoyService),
              ],
            ),
          ),

          // 5. Intercom & SOS Bottom Dock
          _buildIntercomAndSosDock(convoy, currentRider, convoyService),
        ],
      ),
    );
  }

  // --- TAB 0: RIDERS VIEW ---
  Widget _buildRidersTab(ConvoyModel convoy, RiderModel myLoc, bool isCreator, ConvoyService service) {
    final ridersList = convoy.riders.values.toList();

    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        // Convoy Spread Header
        ConvoyMetricsBanner(riders: ridersList),
        const SizedBox(height: 10),

        // Creator Trip Control Row
        if (isCreator) ...[
          Row(
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: () {
                    final next = convoy.tripStatus == 'STARTED' ? 'PAUSED' : 'STARTED';
                    service.updateTripState(next);
                  },
                  icon: Icon(
                    convoy.tripStatus == 'STARTED' ? Icons.pause_rounded : Icons.play_arrow_rounded,
                    size: 16,
                  ),
                  label: Text(convoy.tripStatus == 'STARTED' ? 'Pause Trip' : 'Resume Trip'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: convoy.tripStatus == 'STARTED' ? AppTheme.hyperAmber : AppTheme.emeraldSafe,
                    foregroundColor: Colors.black,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed: () {
                  showDialog(
                    context: context,
                    builder: (ctx) => AlertDialog(
                      backgroundColor: AppTheme.slateCard,
                      title: const Text('🛑 End Convoy Ride?', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                      content: const Text(
                        'This will conclude the active ride for all members and save the journey to everyone\'s trip history.',
                        style: TextStyle(color: AppTheme.textSecondary, fontSize: 13),
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(ctx),
                          child: const Text('Cancel', style: TextStyle(color: AppTheme.textMuted)),
                        ),
                        ElevatedButton(
                          onPressed: () {
                            Navigator.pop(ctx);
                            service.updateTripState('ENDED');
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text('Convoy ride ended and journey saved to Trip History.'),
                                  backgroundColor: AppTheme.emeraldSafe,
                                ),
                              );
                              Navigator.pop(context);
                            }
                          },
                          style: ElevatedButton.styleFrom(backgroundColor: AppTheme.laserRed),
                          child: const Text('End & Save Trip', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                        ),
                      ],
                    ),
                  );
                },
                icon: const Icon(Icons.stop_rounded, color: AppTheme.laserRed, size: 16),
                label: const Text('End Trip', style: TextStyle(color: AppTheme.laserRed)),
                style: OutlinedButton.styleFrom(side: const BorderSide(color: AppTheme.laserRed)),
              ),
            ],
          ),
          const SizedBox(height: 12),
        ],

        // Riders Cards
        ...ridersList.map((member) {
          final isSelf = member.userId == myLoc.userId;
          final isOffline = !isSelf && member.lastSeenEpochMs > 0 && (DateTime.now().millisecondsSinceEpoch - member.lastSeenEpochMs) > 60000;
          final minutesSinceSeen = isOffline
              ? ((DateTime.now().millisecondsSinceEpoch - member.lastSeenEpochMs) / 60000).round()
              : 0;
          final rel = TelemetryUtils.getRelativePosition(
            myLat: myLoc.lat,
            myLng: myLoc.lng,
            myHeading: myLoc.heading,
            otherLat: member.lat,
            otherLng: member.lng,
          );

          return Card(
            color: isSelf ? AppTheme.slateCard : AppTheme.elevatedCard,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            margin: const EdgeInsets.only(bottom: 8),
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: () => _showMemberProfileDialog(context, member, service, myLoc.userId),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: [
                    // Member Avatar with Role Ring
                    Stack(
                      children: [
                        CircleAvatar(
                          radius: 20,
                          backgroundColor: isSelf ? AppTheme.neonCyan : (isOffline ? AppTheme.hyperAmber : AppTheme.devmonksPurple),
                          child: Text(
                            member.name.isNotEmpty ? member.name[0].toUpperCase() : 'R',
                            style: TextStyle(
                              color: (isSelf || isOffline) ? Colors.black : Colors.white,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        if (member.role == 'LEAD')
                          Positioned(
                            bottom: 0,
                            right: 0,
                            child: Container(
                              padding: const EdgeInsets.all(2),
                              decoration: const BoxDecoration(shape: BoxShape.circle, color: AppTheme.hyperAmber),
                              child: const Icon(Icons.star, size: 10, color: Colors.black),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(width: 12),

                    // Name, vehicle, and Ahead/Behind chip
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Text(
                                member.name + (isSelf ? ' (You)' : ''),
                                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14),
                              ),
                              const Spacer(),
                              if (!isSelf && !isOffline)
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: Color(rel.colorHex).withOpacity(0.15),
                                    borderRadius: BorderRadius.circular(6),
                                    border: Border.all(color: Color(rel.colorHex)),
                                  ),
                                  child: Text(
                                    '${rel.symbol} ${rel.label} (${rel.formattedDistance})',
                                    style: TextStyle(
                                      color: Color(rel.colorHex),
                                      fontSize: 10,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                              if (isOffline)
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: AppTheme.laserRed.withOpacity(0.2),
                                    borderRadius: BorderRadius.circular(6),
                                    border: Border.all(color: AppTheme.laserRed),
                                  ),
                                  child: Text(
                                    'OFFLINE · ${minutesSinceSeen <= 1 ? "1m" : "${minutesSinceSeen}m"} ago',
                                    style: const TextStyle(
                                      color: AppTheme.laserRed,
                                      fontSize: 10,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                          const SizedBox(height: 3),
                          Text(
                            member.vehicleType + (member.vehicleNo.isNotEmpty ? ' · ${member.vehicleNo}' : ''),
                            style: const TextStyle(color: AppTheme.textSecondary, fontSize: 11),
                          ),
                          if (isOffline) ...[
                            const SizedBox(height: 4),
                            Row(
                              children: [
                                const Icon(Icons.signal_cellular_connected_no_internet_4_bar_rounded, size: 12, color: AppTheme.laserRed),
                                const SizedBox(width: 4),
                                const Text(
                                  'Signal lost · Last captured location retained',
                                  style: TextStyle(color: AppTheme.laserRed, fontSize: 10, fontWeight: FontWeight.bold),
                                ),
                              ],
                            ),
                            if (member.lat != 0.0 || member.lng != 0.0) ...[
                              const SizedBox(height: 6),
                              SizedBox(
                                height: 26,
                                child: ElevatedButton.icon(
                                  onPressed: () {
                                    Navigator.push(
                                      context,
                                      MaterialPageRoute(
                                        builder: (_) => LiveCockpitMapScreen(convoyId: convoy.groupId),
                                      ),
                                    );
                                  },
                                  icon: const Icon(Icons.near_me_rounded, size: 12, color: Colors.black),
                                  label: const Text('Navigate to Last Location', style: TextStyle(color: Colors.black, fontSize: 10, fontWeight: FontWeight.bold)),
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: AppTheme.hyperAmber,
                                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 0),
                                  ),
                                ),
                              ),
                            ],
                          ],
                          if (member.statusReason.isNotEmpty) ...[
                            const SizedBox(height: 4),
                            Builder(
                              builder: (_) {
                                final info = _getStatusInfo(member.statusReason);
                                final isMedical = member.statusReason == 'MEDICAL';
                                final badgeColor = isMedical ? AppTheme.laserRed : AppTheme.hyperAmber;
                                return Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: badgeColor.withOpacity(0.2),
                                    borderRadius: BorderRadius.circular(4),
                                    border: Border.all(color: badgeColor.withOpacity(0.6)),
                                  ),
                                  child: Text(
                                    '${info['emoji']} ${info['label']}${member.statusMessage.isNotEmpty ? ": ${member.statusMessage}" : ""}',
                                    style: TextStyle(color: badgeColor, fontSize: 10, fontWeight: FontWeight.bold),
                                  ),
                                );
                              },
                            ),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),

                    // Speedometer & Battery
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(
                          '${member.speedKmh.round()} km/h',
                          style: const TextStyle(color: AppTheme.neonCyan, fontWeight: FontWeight.bold, fontSize: 13),
                        ),
                        Text(
                          TelemetryUtils.formatHeading(member.heading),
                          style: const TextStyle(color: AppTheme.textMuted, fontSize: 10),
                        ),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              member.batteryLevel > 20 ? Icons.battery_full_rounded : Icons.battery_alert_rounded,
                              size: 12,
                              color: member.batteryLevel > 20 ? AppTheme.emeraldSafe : AppTheme.laserRed,
                            ),
                            Text(
                              '${member.batteryLevel}%',
                              style: const TextStyle(color: AppTheme.textMuted, fontSize: 10),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          );
        }),
      ],
    );
  }

  // --- TAB 1: CHAT & QUICK COMMS VIEW ---
  Widget _buildChatTab(ConvoyModel convoy, RiderModel myLoc, ConvoyService service) {
    return Column(
      children: [
        // Quick Action Cards Row
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          color: AppTheme.elevatedCard,
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                _buildQuickCardBtn('⏱️ Wait 2 min', () => service.requestWait(myLoc.name)),
                _buildQuickCardBtn('⛽ Need Fuel', () {
                  service.sendGroupMessage(
                    senderId: myLoc.userId,
                    senderName: myLoc.name,
                    text: '⛽ Looking for a fuel station soon.',
                    isQuickCard: true,
                    cardType: 'FUEL',
                  );
                }),
                _buildQuickCardBtn('🛑 Regroup', () {
                  service.sendGroupMessage(
                    senderId: myLoc.userId,
                    senderName: myLoc.name,
                    text: '🛑 Regroup at next available toll or stop.',
                    isQuickCard: true,
                    cardType: 'REGROUP',
                  );
                }),
                _buildQuickCardBtn('🔧 Issue', () {
                  service.sendGroupMessage(
                    senderId: myLoc.userId,
                    senderName: myLoc.name,
                    text: '🔧 Minor mechanical/bike issue, slowing down.',
                    isQuickCard: true,
                    cardType: 'MECHANICAL',
                  );
                }),
              ],
            ),
          ),
        ),

        // Message List
        Expanded(
          child: convoy.messages.isEmpty
              ? const Center(
                  child: Text('No group messages yet. Broadcast to your riders!', style: TextStyle(color: AppTheme.textMuted)),
                )
              : ListView.builder(
                  controller: _scrollController,
                  padding: const EdgeInsets.all(12),
                  itemCount: convoy.messages.length,
                  itemBuilder: (ctx, idx) {
                    final msg = convoy.messages[idx];
                    final isMe = msg.senderId == myLoc.userId;

                    return Align(
                      alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
                      child: Container(
                        margin: const EdgeInsets.only(bottom: 8),
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.75),
                        decoration: BoxDecoration(
                          color: msg.isQuickCard
                              ? AppTheme.devmonksPurple.withOpacity(0.3)
                              : (isMe ? AppTheme.neonCyan.withOpacity(0.2) : AppTheme.elevatedCard),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: msg.isQuickCard ? AppTheme.devmonksPurple : (isMe ? AppTheme.neonCyan : AppTheme.glassBorder),
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              msg.senderName,
                              style: TextStyle(
                                color: isMe ? AppTheme.neonCyan : AppTheme.hyperAmber,
                                fontSize: 10,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(msg.text, style: const TextStyle(color: Colors.white, fontSize: 13)),
                          ],
                        ),
                      ),
                    );
                  },
                ),
        ),

        // Chat Input Row
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          color: AppTheme.slateCard,
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _messageController,
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                  decoration: InputDecoration(
                    hintText: 'Broadcast quick update...',
                    hintStyle: const TextStyle(color: AppTheme.textMuted),
                    filled: true,
                    fillColor: AppTheme.elevatedCard,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(20), borderSide: BorderSide.none),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                icon: const Icon(Icons.send_rounded, color: AppTheme.neonCyan),
                onPressed: () {
                  final txt = _messageController.text.trim();
                  if (txt.isNotEmpty) {
                    service.sendGroupMessage(
                      senderId: myLoc.userId,
                      senderName: myLoc.name,
                      text: txt,
                    );
                    _messageController.clear();
                  }
                },
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildQuickCardBtn(String label, VoidCallback onTap) {
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: ActionChip(
        label: Text(label, style: const TextStyle(color: Colors.white, fontSize: 11)),
        backgroundColor: AppTheme.slateCard,
        side: const BorderSide(color: AppTheme.glassBorder),
        onPressed: onTap,
      ),
    );
  }

  // --- TAB 2: STOPS VIEW ---
  Widget _buildStopsTab(ConvoyModel convoy, bool isCreator, ConvoyService service) {
    // Start, stops (with suggestions), destination and route summary; the lead edits, others suggest.
    return RouteStopsPanel(convoy: convoy);
  }

  // --- TAB 3: SETTINGS VIEW ---
  Widget _buildSettingsTab(ConvoyModel convoy, bool isCreator, ConvoyService service) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text('SAFETY & TELEMETRY THRESHOLDS', style: TextStyle(color: AppTheme.neonCyan, fontWeight: FontWeight.bold, fontSize: 12)),
        const SizedBox(height: 12),

        GlassCard(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('Convoy Separation Warning', style: TextStyle(color: Colors.white, fontSize: 13)),
                  Text('${convoy.distanceThresholdMeters.round()} m', style: const TextStyle(color: AppTheme.neonCyan, fontWeight: FontWeight.bold)),
                ],
              ),
              Slider(
                value: convoy.distanceThresholdMeters,
                min: 500,
                max: 5000,
                divisions: 9,
                activeColor: AppTheme.neonCyan,
                onChanged: isCreator
                    ? (v) => service.updateGroupConfig(distanceThresholdMeters: v)
                    : null,
              ),
              const Text('Alerts riders when they stretch beyond this distance from the pack.', style: TextStyle(color: AppTheme.textMuted, fontSize: 11)),
            ],
          ),
        ),

        const SizedBox(height: 12),

        GlassCard(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('Stopped Duration Alert', style: TextStyle(color: Colors.white, fontSize: 13)),
                  Text('${convoy.stopThresholdSeconds ~/ 60} min', style: const TextStyle(color: AppTheme.hyperAmber, fontWeight: FontWeight.bold)),
                ],
              ),
              Slider(
                value: convoy.stopThresholdSeconds.toDouble(),
                min: 60,
                max: 600,
                divisions: 9,
                activeColor: AppTheme.hyperAmber,
                onChanged: isCreator
                    ? (v) => service.updateGroupConfig(stopThresholdSeconds: v.toInt())
                    : null,
              ),
              const Text('Automatically prompts the rider to submit status if stationary.', style: TextStyle(color: AppTheme.textMuted, fontSize: 11)),
            ],
          ),
        ),

        const SizedBox(height: 12),

        GlassCard(
          padding: const EdgeInsets.all(14),
          child: SwitchListTile(
            title: const Text('Voice Guidance & Alerts (TTS)', style: TextStyle(color: Colors.white, fontSize: 13)),
            subtitle: const Text('Spoken audio warnings for separation and emergency stops.', style: TextStyle(color: AppTheme.textMuted, fontSize: 11)),
            value: convoy.voiceGuidanceEnabled,
            activeColor: AppTheme.neonCyan,
            onChanged: (v) => service.updateGroupConfig(voiceGuidanceEnabled: v),
          ),
        ),

        const SizedBox(height: 12),

        GlassCard(
          padding: const EdgeInsets.all(14),
          child: SwitchListTile(
            title: const Text('Real-Time GPS Tracking', style: TextStyle(color: Colors.white, fontSize: 13)),
            subtitle: Text(
              service.isRealGpsActive ? 'Live GPS Active · Tracking your position' : 'GPS Paused · Tap to resume tracking',
              style: const TextStyle(color: AppTheme.textMuted, fontSize: 11),
            ),
            value: service.isRealGpsActive,
            activeColor: AppTheme.emeraldSafe,
            onChanged: (v) {
              if (v) {
                service.startRealGpsTracking(convoy.createdByUserId);
              } else {
                service.stopRealGpsTracking();
              }
            },
          ),
        ),
      ],
    );
  }

  // --- BOTTOM DOCK: INTERCOM & SOS ---
  Widget _buildIntercomAndSosDock(ConvoyModel convoy, RiderModel myLoc, ConvoyService service) {
    return IntercomDock(
      convoy: convoy,
      me: myLoc,
      onSos: () {
        service.triggerSosAlert(
          userId: myLoc.userId,
          userName: myLoc.name,
          lat: myLoc.lat,
          lng: myLoc.lng,
          type: 'CRASH_OR_EMERGENCY',
        );
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('🚨 SOS EMERGENCY BROADCAST TO CONVOY!'),
            backgroundColor: AppTheme.laserRed,
          ),
        );
      },
    );
  }
}

class ConvoyMetricsBanner extends StatelessWidget {
  final List<RiderModel> riders;

  const ConvoyMetricsBanner({super.key, required this.riders});

  @override
  Widget build(BuildContext context) {
    final metrics = TelemetryUtils.calculateConvoyMetrics(riders);

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppTheme.slateCard,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.glassBorder),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          _buildMetric('FORMATION', metrics.status, Color(metrics.statusColor)),
          _buildMetric('AVG SPEED', '${metrics.averageSpeedKmh.round()} km/h', AppTheme.neonCyan),
          _buildMetric('SPREAD', '${metrics.spreadKm.toStringAsFixed(1)} km', AppTheme.hyperAmber),
          _buildMetric('ACTIVE', '${metrics.movingRiderCount}/${metrics.activeRiderCount}', AppTheme.emeraldSafe),
        ],
      ),
    );
  }

  Widget _buildMetric(String label, String value, Color color) {
    return Column(
      children: [
        Text(label, style: const TextStyle(color: AppTheme.textMuted, fontSize: 9, fontWeight: FontWeight.bold)),
        const SizedBox(height: 2),
        Text(value, style: TextStyle(color: color, fontWeight: FontWeight.bold, fontSize: 12)),
      ],
    );
  }
}
