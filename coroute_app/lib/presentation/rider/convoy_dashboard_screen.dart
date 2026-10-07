import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
import '../../core/config/app_config.dart';
import '../../core/constants/telemetry_utils.dart';
import '../../core/constants/app_constants.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/glass_card.dart';
import '../../data/models/convoy_model.dart';
import '../../data/models/rider_model.dart';
import '../../data/services/auth_service.dart';
import '../../data/services/convoy_service.dart';
import '../widgets/connection_banner.dart';
import '../widgets/emergency_sos_sheet.dart';
import '../widgets/intercom_dock.dart';
import '../widgets/rider_status_sheet.dart';
import 'live_cockpit_map_screen.dart';
import '../timeline/live_timeline_screen.dart';
import '../trip_planner/route_stops_panel.dart';
import '../../domain/timeline/timeline_text.dart';

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

  Map<String, String> _getStatusInfo(String code) {
    return {
      'code': code,
      'label': RiderStatusSheet.getStatusLabel(code),
    };
  }

  void _shareInvite(ConvoyModel convoy) {
    final link = '${AppConfig.apiBaseUrl}/join/${convoy.joinCode}';
    SharePlus.instance.share(ShareParams(
      text: 'Join my CoRoute convoy "${convoy.name}". Code ${convoy.joinCode}. Tap to open: $link',
      subject: 'CoRoute convoy: ${convoy.name}',
    ));
  }

  Future<void> _confirmLeave(ConvoyService service, String userId) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.slateCard,
        title: Text('Leave this convoy?', style: TextStyle(color: AppTheme.textPrimary)),
        content: Text('Your group will stop seeing your position. Your ride so far is kept in trip history.', style: TextStyle(color: AppTheme.textSecondary)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Stay')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: Text('Leave', style: TextStyle(color: AppTheme.laserRed))),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    service.leaveActiveConvoy(userId);
    Navigator.pop(context);
  }

  void _showStatusSheet(BuildContext context, String userId) {
    RiderStatusSheet.show(context, userId: userId);
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
              decoration: BoxDecoration(
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
                  Text(member.name, style: TextStyle(color: AppTheme.textPrimary, fontSize: 16)),
                  Text(member.vehicleType, style: TextStyle(color: AppTheme.textSecondary, fontSize: 12)),
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
              Divider(color: AppTheme.glassBorder),
            ],
            if (member.phone.isNotEmpty) ...[
              _buildProfileRow(Icons.phone_outlined, 'Rider Contact', member.phone),
              Divider(color: AppTheme.glassBorder),
            ],
            if (member.emergencyContact.isNotEmpty) ...[
              _buildProfileRow(
                Icons.emergency_outlined,
                'Emergency SOS Contact',
                '${member.emergencyContactName.isNotEmpty ? "${member.emergencyContactName} - " : ""}${member.emergencyContact}',
              ),
              Divider(color: AppTheme.glassBorder),
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
                icon: Icon(Icons.link_rounded, color: AppTheme.neonCyan, size: 16),
                label: Text('Pair as Pillion (Driver Separation Alert)', style: TextStyle(color: AppTheme.neonCyan, fontSize: 12)),
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('Close', style: TextStyle(color: AppTheme.neonCyan)),
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
                Text(label, style: TextStyle(color: AppTheme.textMuted, fontSize: 10)),
                Text(value, style: TextStyle(color: AppTheme.textPrimary, fontSize: 13, fontWeight: FontWeight.bold)),
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
        body: Center(
          child: Text('Convoy session not found or concluded.', style: TextStyle(color: AppTheme.textPrimary)),
        ),
      );
    }

    _checkWaitRequests(convoy);
    if (convoyService.sosRequestedFromNotification) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        convoyService.clearSosRequest();
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
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
          icon: Icon(Icons.arrow_back_rounded, color: AppTheme.textPrimary),
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
                    style: TextStyle(color: AppTheme.textPrimary, fontSize: 16, fontWeight: FontWeight.bold),
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
                GestureDetector(
                  onTap: () => _shareInvite(convoy),
                  onLongPress: () {
                    Clipboard.setData(ClipboardData(text: convoy.joinCode));
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Code ${convoy.joinCode} copied')));
                  },
                  child: Text(
                    'CODE ${convoy.joinCode} · Invite',
                    style: TextStyle(color: AppTheme.neonCyan, fontSize: 11, fontWeight: FontWeight.bold, letterSpacing: 0.8),
                  ),
                ),
              ],
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: Icon(Icons.timeline_rounded, color: AppTheme.neonCyan),
            tooltip: 'Group timeline',
            onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => LiveTimelineScreen(groupId: convoy.groupId))),
          ),
          IconButton(
            icon: Icon(Icons.map_rounded, color: AppTheme.neonCyan),
            tooltip: 'Live map',
            onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => LiveCockpitMapScreen(convoyId: convoy.groupId))),
          ),
          PopupMenuButton<String>(
            icon: Icon(Icons.more_vert_rounded, color: AppTheme.textPrimary),
            color: AppTheme.elevatedCard,
            onSelected: (val) {
              switch (val) {
                case 'invite':
                  _shareInvite(convoy);
                  break;
                case 'focus':
                  setState(() => _isFocusMode = !_isFocusMode);
                  break;
                case 'leave':
                  _confirmLeave(convoyService, currentUserId);
                  break;
              }
            },
            itemBuilder: (ctx) => [
              PopupMenuItem(value: 'invite', child: Text('Invite riders', style: TextStyle(color: AppTheme.textPrimary, fontSize: 13))),
              PopupMenuItem(value: 'focus', child: Text(_isFocusMode ? 'Exit focus mode' : 'Focus mode', style: TextStyle(color: AppTheme.textPrimary, fontSize: 13))),
              PopupMenuItem(value: 'leave', child: Text('Leave convoy', style: TextStyle(color: AppTheme.laserRed, fontSize: 13))),
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
            const Tab(text: 'Settings'),
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
                          'Your SOS is on',
                          style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold, fontSize: 13),
                        ),
                        Text(
                          'Your convoy can see where you are.',
                          style: TextStyle(color: Colors.black87, fontSize: 11),
                        ),
                      ],
                    ),
                  ),
                  ElevatedButton(
                    onPressed: () {
                      final alertId = myActiveSosAlerts.last.alertId;
                      convoyService.resolveSosAlert(alertId);
                      convoyService.cancelMySos();
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('SOS cancelled. Your convoy sees that you are OK.')),
                      );
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.black,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    ),
                    child: const Text('I am safe', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11)),
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
                          'SOS: ${otherSosAlerts.last.userName} needs help',
                          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13),
                        ),
                        Text(
                          TimelineText.reason(otherSosAlerts.last.alertType),
                          style: TextStyle(color: Colors.white70, fontSize: 11),
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
                    child: const Text('Show on map', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11)),
                  ),
                  IconButton(
                    icon: Icon(Icons.check_circle_outline, color: Colors.white, size: 20),
                    tooltip: 'Mark as handled',
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

          // 3. Stopped for longer than the group's stop limit: one slim line, details in a sheet.
          if (currentRider.statusReason.isEmpty &&
              currentRider.stoppedSince > 0 &&
              DateTime.now().millisecondsSinceEpoch - currentRider.stoppedSince >= convoy.stopThresholdSeconds * 1000)
            Container(
              margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              padding: const EdgeInsets.only(left: 12, right: 4),
              decoration: BoxDecoration(
                color: AppTheme.hyperAmber.withOpacity(0.12),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: AppTheme.hyperAmber.withOpacity(0.4)),
              ),
              child: Row(
                children: [
                  Icon(Icons.local_parking_rounded, color: AppTheme.hyperAmber, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Stopped ${((DateTime.now().millisecondsSinceEpoch - currentRider.stoppedSince) ~/ 60000)} min',
                      style: TextStyle(color: AppTheme.hyperAmber, fontSize: 13, fontWeight: FontWeight.w600),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  TextButton(
                    onPressed: () => _showStatusSheet(context, currentRider.userId),
                    child: const Text('Tell the group why'),
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
                  Icon(Icons.info_outline_rounded, size: 18, color: currentRider.statusReason == 'MEDICAL' ? AppTheme.laserRed : AppTheme.hyperAmber),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Your Status: ${_getStatusInfo(currentRider.statusReason)['label']}${currentRider.statusMessage.isNotEmpty ? " (${currentRider.statusMessage})" : ""}',
                      style: TextStyle(color: AppTheme.textPrimary, fontSize: 12, fontWeight: FontWeight.bold),
                    ),
                  ),
                  TextButton.icon(
                    onPressed: () {
                      convoyService.updateStatusReason(
                        userId: currentRider.userId,
                        reason: '',
                      );
                    },
                    icon: Icon(Icons.check_circle_outline, size: 16, color: AppTheme.emeraldSafe),
                    label: Text('Clear', style: TextStyle(color: AppTheme.emeraldSafe, fontSize: 12)),
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
                      title: Text('End the ride for everyone?', style: TextStyle(color: AppTheme.textPrimary, fontWeight: FontWeight.bold)),
                      content: Text(
                        'This will conclude the active ride for all members and save the journey to everyone\'s trip history.',
                        style: TextStyle(color: AppTheme.textSecondary, fontSize: 13),
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(ctx),
                          child: Text('Cancel', style: TextStyle(color: AppTheme.textMuted)),
                        ),
                        ElevatedButton(
                          onPressed: () {
                            Navigator.pop(ctx);
                            service.updateTripState('ENDED');
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
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
                icon: Icon(Icons.stop_rounded, color: AppTheme.laserRed, size: 16),
                label: Text('End Trip', style: TextStyle(color: AppTheme.laserRed)),
                style: OutlinedButton.styleFrom(side: BorderSide(color: AppTheme.laserRed)),
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
                              decoration: BoxDecoration(shape: BoxShape.circle, color: AppTheme.hyperAmber),
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
                                style: TextStyle(color: AppTheme.textPrimary, fontWeight: FontWeight.bold, fontSize: 14),
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
                                    '${rel.label} (${rel.formattedDistance})',
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
                                    style: TextStyle(
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
                            style: TextStyle(color: AppTheme.textSecondary, fontSize: 11),
                          ),
                          if (isOffline) ...[
                            const SizedBox(height: 4),
                            Row(
                              children: [
                                Icon(Icons.signal_cellular_connected_no_internet_4_bar_rounded, size: 12, color: AppTheme.laserRed),
                                const SizedBox(width: 4),
                                Flexible(
                                  child: Text(
                                    'Signal lost · last known position shown',
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(color: AppTheme.laserRed, fontSize: 10, fontWeight: FontWeight.bold),
                                  ),
                                ),
                              ],
                            ),
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
                                    '${info['label']}${member.statusMessage.isNotEmpty ? ": ${member.statusMessage}" : ""}',
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
                          style: TextStyle(color: AppTheme.neonCyan, fontWeight: FontWeight.bold, fontSize: 13),
                        ),
                        Text(
                          TelemetryUtils.formatHeading(member.heading),
                          style: TextStyle(color: AppTheme.textMuted, fontSize: 10),
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
                              style: TextStyle(color: AppTheme.textMuted, fontSize: 10),
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
                _buildQuickCardBtn('Wait 2 min', () => service.requestWait(myLoc.name)),
                _buildQuickCardBtn('Need fuel', () {
                  service.sendGroupMessage(
                    senderId: myLoc.userId,
                    senderName: myLoc.name,
                    text: 'Looking for a fuel station soon.',
                    isQuickCard: true,
                    cardType: 'FUEL',
                  );
                }),
                _buildQuickCardBtn('Regroup', () {
                  service.sendGroupMessage(
                    senderId: myLoc.userId,
                    senderName: myLoc.name,
                    text: 'Regroup at the next toll or stop.',
                    isQuickCard: true,
                    cardType: 'REGROUP',
                  );
                }),
                _buildQuickCardBtn('Bike issue', () {
                  service.sendGroupMessage(
                    senderId: myLoc.userId,
                    senderName: myLoc.name,
                    text: 'Small bike problem, slowing down.',
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
              ? Center(
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
                            Text(msg.text, style: TextStyle(color: AppTheme.textPrimary, fontSize: 13)),
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
                  style: TextStyle(color: AppTheme.textPrimary, fontSize: 13),
                  decoration: InputDecoration(
                    hintText: 'Broadcast quick update...',
                    hintStyle: TextStyle(color: AppTheme.textMuted),
                    filled: true,
                    fillColor: AppTheme.elevatedCard,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(20), borderSide: BorderSide.none),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                icon: Icon(Icons.send_rounded, color: AppTheme.neonCyan),
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
        label: Text(label, style: TextStyle(color: AppTheme.textPrimary, fontSize: 11)),
        backgroundColor: AppTheme.slateCard,
        side: BorderSide(color: AppTheme.glassBorder),
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
        Text('SAFETY & TELEMETRY THRESHOLDS', style: TextStyle(color: AppTheme.neonCyan, fontWeight: FontWeight.bold, fontSize: 12)),
        const SizedBox(height: 12),

        GlassCard(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(child: Text('Convoy Separation Warning', style: TextStyle(color: AppTheme.textPrimary, fontSize: 13))),
                  Text('${convoy.distanceThresholdMeters.round()} m', style: TextStyle(color: AppTheme.neonCyan, fontWeight: FontWeight.bold)),
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
              Text('Alerts riders when they stretch beyond this distance from the pack.', style: TextStyle(color: AppTheme.textMuted, fontSize: 11)),
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
                  Expanded(child: Text('Stopped Duration Alert', style: TextStyle(color: AppTheme.textPrimary, fontSize: 13))),
                  Text('${convoy.stopThresholdSeconds ~/ 60} min', style: TextStyle(color: AppTheme.hyperAmber, fontWeight: FontWeight.bold)),
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
              Text('Automatically prompts the rider to submit status if stationary.', style: TextStyle(color: AppTheme.textMuted, fontSize: 11)),
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
                children: [
                  Expanded(child: Text('Group speed limit', style: TextStyle(color: AppTheme.textPrimary, fontSize: 13))),
                  Text(convoy.speedLimitKmh > 0 ? '${convoy.speedLimitKmh} km/h' : 'Off',
                      style: TextStyle(color: AppTheme.speedWarning, fontWeight: FontWeight.bold)),
                ],
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final v in AppConstants.speedLimitChoices)
                    ChoiceChip(
                      label: Text(v == 0 ? 'Off' : '$v'),
                      selected: convoy.speedLimitKmh == v,
                      onSelected: isCreator ? (_) => service.updateGroupConfig(speedLimitKmh: v) : null,
                      selectedColor: AppTheme.speedWarning.withOpacity(0.2),
                      labelStyle: TextStyle(color: convoy.speedLimitKmh == v ? AppTheme.speedWarning : AppTheme.textSecondary, fontSize: 12),
                      backgroundColor: AppTheme.slateCard,
                      side: BorderSide(color: AppTheme.subtleBorder),
                      showCheckmark: false,
                    ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                isCreator
                    ? 'When a rider stays over this speed for 10 seconds it is logged on the timeline and everyone is told once.'
                    : 'Set by the lead. Riding over it is logged on the timeline and the group is told once.',
                style: TextStyle(color: AppTheme.textMuted, fontSize: 11),
              ),
            ],
          ),
        ),

        const SizedBox(height: 12),

        GlassCard(
          padding: const EdgeInsets.all(14),
          child: SwitchListTile(
            title: Text('Voice Guidance & Alerts (TTS)', style: TextStyle(color: AppTheme.textPrimary, fontSize: 13)),
            subtitle: Text('Spoken audio warnings for separation and emergency stops.', style: TextStyle(color: AppTheme.textMuted, fontSize: 11)),
            value: convoy.voiceGuidanceEnabled,
            activeColor: AppTheme.neonCyan,
            onChanged: (v) => service.updateGroupConfig(voiceGuidanceEnabled: v),
          ),
        ),

        const SizedBox(height: 12),

        GlassCard(
          padding: const EdgeInsets.all(14),
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.my_location_rounded, color: service.isRealGpsActive ? AppTheme.emeraldSafe : AppTheme.hyperAmber),
            title: Text('Location sharing', style: TextStyle(color: AppTheme.textPrimary, fontSize: 13)),
            subtitle: Text(
              service.isRealGpsActive
                  ? 'On while you are in this convoy. It stops when you leave.'
                  : 'Waiting for GPS. Check that location is on and allowed for CoRoute.',
              style: TextStyle(color: AppTheme.textMuted, fontSize: 11),
            ),
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
        EmergencySosSheet.show(
          context,
          lat: myLoc.lat,
          lng: myLoc.lng,
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
        Text(label, style: TextStyle(color: AppTheme.textMuted, fontSize: 9, fontWeight: FontWeight.bold)),
        const SizedBox(height: 2),
        Text(value, style: TextStyle(color: color, fontWeight: FontWeight.bold, fontSize: 12)),
      ],
    );
  }
}
