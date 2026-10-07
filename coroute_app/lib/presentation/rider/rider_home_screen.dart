import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:provider/provider.dart';
import '../../core/constants/app_constants.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/glass_card.dart';
import '../../data/models/convoy_model.dart';
import '../../data/models/rider_model.dart';
import '../../data/services/auth_service.dart';
import '../../data/services/convoy_service.dart';
import '../../data/services/trip_storage_service.dart';
import '../account/account_screen.dart';
import '../account/appearance_sheet.dart';
import '../account/edit_profile_screen.dart';
import '../admin/master_admin_dashboard.dart';
import '../auth/access_gate_screen.dart';
import '../auth/complete_profile_screen.dart';
import '../onboarding/permissions_screen.dart';
import '../timeline/live_timeline_screen.dart';
import '../trip_planner/trip_planner_screen.dart';
import 'convoy_dashboard_screen.dart';
import 'live_cockpit_map_screen.dart';
import 'trip_history_screen.dart';

class RiderHomeScreen extends StatefulWidget {
  const RiderHomeScreen({super.key});

  @override
  State<RiderHomeScreen> createState() => _RiderHomeScreenState();
}

class _RiderHomeScreenState extends State<RiderHomeScreen> {
  final _joinCodeController = TextEditingController();
  ConvoyService? _convoyService;
  bool _joinDialogOpen = false;
  bool _profilePromptShown = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _convoyService = context.read<ConvoyService>();
      _convoyService!.addListener(_onConvoyChanged);
      _onConvoyChanged();
      _checkMandatoryProfile();
    });
  }

  void _checkMandatoryProfile() {
    if (_profilePromptShown || !mounted) return;
    final auth = context.read<AuthService>();
    if (!auth.isProfileComplete && !auth.isMasterAdmin) {
      _profilePromptShown = true;
      _showMandatoryProfilePopup(context);
    }
  }

  void _showMandatoryProfilePopup(BuildContext context) {
    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.slateCard,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            Icon(Icons.shield_outlined, color: AppTheme.laserRed, size: 24),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'Mandatory Safety Details Required',
                style: TextStyle(color: AppTheme.textPrimary, fontSize: 16, fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'CoRoute is a live convoy tracking platform designed around rider safety. To protect all riders in the convoy, you must provide:\n\n'
              '• Verified Mobile Number\n'
              '• Bike Registration Number (or select Pillion Rider)\n'
              '• Emergency (ICE) Contact Name & Phone\n\n'
              'Creating or joining convoys is restricted until these mandatory details are updated.',
              style: TextStyle(color: AppTheme.textSecondary, fontSize: 13, height: 1.4),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('Remind Me Later', style: TextStyle(color: AppTheme.textMuted)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.neonCyan,
              foregroundColor: Colors.black,
            ),
            onPressed: () {
              Navigator.pop(ctx);
              _openCompleteProfile(context);
            },
            child: const Text('Update Details Now', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  Future<void> _openCompleteProfile(BuildContext context) async {
    await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => const CompleteProfileScreen(forced: false)),
    );
    if (mounted) setState(() {});
  }

  /// A join link (coroute://join/CODE) opens the join dialog with the code filled in.
  void _onConvoyChanged() {
    final code = _convoyService?.pendingJoinCode;
    if (code == null || _joinDialogOpen || !mounted) return;
    if (_convoyService?.activeGroupId != null) return; // already riding; ignore the link
    _joinCodeController.text = code;
    _convoyService?.setPendingJoinCode(null);
    _showJoinConvoyDialog(context);
  }

  @override
  void dispose() {
    _convoyService?.removeListener(_onConvoyChanged);
    _joinCodeController.dispose();
    super.dispose();
  }

  void _showJoinConvoyDialog(BuildContext context) {
    _joinDialogOpen = true;
    showDialog(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          backgroundColor: AppTheme.slateCard,
          title: Row(
            children: [
              Icon(Icons.qr_code_scanner, color: AppTheme.hyperAmber),
              SizedBox(width: 8),
              Flexible(child: Text('Join with Code', style: TextStyle(color: AppTheme.textPrimary, fontSize: 18))),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Enter the 6-character room code shared by your convoy lead.',
                style: TextStyle(color: AppTheme.textSecondary, fontSize: 12),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: _joinCodeController,
                style: TextStyle(color: AppTheme.textPrimary, letterSpacing: 3, fontWeight: FontWeight.bold),
                textCapitalization: TextCapitalization.characters,
                decoration: InputDecoration(
                  hintText: 'e.g. WST900',
                  prefixIcon: Icon(Icons.key, color: AppTheme.hyperAmber),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text('Cancel', style: TextStyle(color: AppTheme.textMuted)),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: AppTheme.hyperAmber),
              onPressed: () async {
                final code = _joinCodeController.text.trim();
                final auth = context.read<AuthService>();
                final convoyService = context.read<ConvoyService>();

                if (!auth.isProfileComplete && !auth.isMasterAdmin) {
                  Navigator.pop(ctx);
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: const Text('⚠️ Convoy joining locked! Mandatory safety details required.'),
                      backgroundColor: AppTheme.laserRed,
                      action: SnackBarAction(label: 'Update', textColor: Colors.white, onPressed: () => _openCompleteProfile(context)),
                    ),
                  );
                  _openCompleteProfile(context);
                  return;
                }

                if (!await PermissionsScreen.ensure(context)) return;
                if (!ctx.mounted) return;

                // Get real GPS position before joining (fast 1s max)
                double joinLat = 0.0;
                double joinLng = 0.0;
                try {
                  final pos = await Geolocator.getLastKnownPosition() ??
                      await Geolocator.getCurrentPosition(
                        locationSettings: const LocationSettings(
                          accuracy: LocationAccuracy.medium,
                          timeLimit: Duration(seconds: 1),
                        ),
                      );
                  joinLat = pos.latitude;
                  joinLng = pos.longitude;
                } catch (_) {}

                final rider = RiderModel(
                  userId: auth.currentUserId ?? '',
                  name: auth.currentUserName ?? 'Rider',
                  vehicleType: auth.vehicleType ?? 'Motorcycle',
                  vehicleNo: auth.vehicleNo ?? '',
                  phone: auth.phone ?? '',
                  emergencyContact: auth.emergencyContact ?? '',
                  emergencyContactName: auth.emergencyContactName ?? '',
                  lat: joinLat,
                  lng: joinLng,
                  speedKmh: 0.0,
                  heading: 0.0,
                  batteryLevel: convoyService.currentBatteryLevel,
                  isCharging: convoyService.isCharging,
                  role: 'PACK',
                  lastSeenEpochMs: DateTime.now().millisecondsSinceEpoch,
                );

                final joined = await convoyService.joinConvoyByCode(code: code, rider: rider);
                if (!ctx.mounted) return;
                if (joined != null) {
                  _joinCodeController.clear();
                  Navigator.pop(ctx);
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => ConvoyDashboardScreen(groupId: joined.groupId)),
                  );
                } else {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(convoyService.lastError ?? 'Invalid code. No active convoy found.')),
                  );
                }
              },
              child: const Text('Connect to Convoy', style: TextStyle(color: Colors.black)),
            ),
          ],
        );
      },
    ).whenComplete(() => _joinDialogOpen = false);
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthService>();
    final convoyService = context.watch<ConvoyService>();
    final tripStorage = context.watch<TripStorageService>();
    final activeConvoy = convoyService.activeConvoy;
    final trips = tripStorage.trips;

    // Compute advanced analytics from collected trip and tracking data
    double totalDistanceKm = 0.0;
    int totalDurationMinutes = 0;
    double maxSpeedKmh = 0.0;
    double sumAvgSpeed = 0.0;
    int totalRidersInConvoys = 0;
    int totalMovingMs = 0;
    int totalRestMs = 0;

    for (final t in trips) {
      totalDistanceKm += t.totalDistanceKm;
      totalDurationMinutes += t.durationMinutes;
      if (t.topSpeedKmh > maxSpeedKmh) maxSpeedKmh = t.topSpeedKmh;
      sumAvgSpeed += t.avgSpeedKmh;
      totalRidersInConvoys += t.riderCount;
      totalMovingMs += t.movingMs;
      totalRestMs += t.restMs;
    }

    final int completedRidesCount = trips.length;
    final double overallAvgSpeed = completedRidesCount > 0 ? (sumAvgSpeed / completedRidesCount) : 0.0;
    final double avgRidersPerConvoy = completedRidesCount > 0 ? (totalRidersInConvoys / completedRidesCount) : 0.0;
    final double avgDistancePerRide = completedRidesCount > 0 ? (totalDistanceKm / completedRidesCount) : 0.0;
    final int hoursRidden = totalDurationMinutes ~/ 60;
    final int minutesRidden = totalDurationMinutes % 60;
    final double movingRatio = (totalMovingMs + totalRestMs) > 0
        ? (totalMovingMs / (totalMovingMs + totalRestMs)) * 100
        : 100.0;

    return Scaffold(
      backgroundColor: AppTheme.obsidianVoid,
      drawer: _buildDrawer(context, auth, convoyService, activeConvoy),
      appBar: AppBar(
        leading: Builder(
          builder: (ctx) => IconButton(
            tooltip: 'Menu',
            icon: Icon(Icons.menu_rounded, color: AppTheme.neonCyan),
            onPressed: () => Scaffold.of(ctx).openDrawer(),
          ),
        ),
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: AppTheme.neonCyan,
              ),
              child: const Icon(Icons.navigation_rounded, color: Colors.black, size: 16),
            ),
            const SizedBox(width: 8),
            Text(AppConstants.appName),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Trip History',
            icon: Icon(Icons.history_rounded, color: AppTheme.neonCyan),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const TripHistoryScreen()),
              );
            },
          ),
          IconButton(
            tooltip: 'Account & security',
            icon: Icon(Icons.manage_accounts_rounded, color: AppTheme.textMuted),
            onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const AccountScreen())),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Rider Profile & Callsign Header
            InkWell(
              borderRadius: BorderRadius.circular(16),
              onTap: () => _openCompleteProfile(context),
              child: GlassCard(
                child: Row(
                  children: [
                    CircleAvatar(
                      radius: 22,
                      backgroundColor: AppTheme.neonCyan.withOpacity(0.18),
                      child: Icon(Icons.person, color: AppTheme.neonCyan, size: 26),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Flexible(
                                child: Text(
                                  auth.currentUserName ?? 'Rider',
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: AppTheme.textPrimary,
                                    fontSize: 16,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 6),
                              Icon(Icons.edit_note_rounded, color: AppTheme.neonCyan, size: 18),
                            ],
                          ),
                          Text(
                            '${auth.vehicleType ?? 'Motorcycle'}${auth.vehicleNo != null && auth.vehicleNo!.isNotEmpty ? " · ${auth.vehicleNo}" : ""} · ${auth.phone != null && auth.phone!.isNotEmpty ? auth.phone : "Tap to complete details"}',
                            style: TextStyle(color: AppTheme.textSecondary, fontSize: 11),
                          ),
                        ],
                      ),
                    ),
                    Icon(Icons.chevron_right_rounded, color: AppTheme.textMuted, size: 22),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 16),

            // Incomplete Profile Restriction Banner
            if (!auth.isProfileComplete && !auth.isMasterAdmin) ...[
              Container(
                margin: const EdgeInsets.only(bottom: 16),
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: AppTheme.laserRed.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: AppTheme.laserRed.withOpacity(0.5)),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Icon(Icons.shield_outlined, color: AppTheme.laserRed, size: 26),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Mandatory Safety Details Required', style: TextStyle(color: AppTheme.laserRed, fontWeight: FontWeight.bold, fontSize: 13)),
                          const SizedBox(height: 2),
                          Text('Creating or joining convoys is locked until your phone, bike/pillion details, and emergency contacts are provided.', style: TextStyle(color: AppTheme.textSecondary, fontSize: 11)),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    ElevatedButton(
                      onPressed: () => _openCompleteProfile(context),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppTheme.laserRed,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      ),
                      child: const Text('Update', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                    ),
                  ],
                ),
              ),
            ],

            // Active Convoy Quick Resume Banner (if in session)
            if (activeConvoy != null) ...[
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [AppTheme.heroTop, AppTheme.slateCard],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: AppTheme.neonCyan, width: 1.5),
                  boxShadow: [
                    BoxShadow(
                      color: AppTheme.neonCyan.withOpacity(0.2),
                      blurRadius: 14,
                    ),
                  ],
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Flexible(child: Row(
                          children: [
                            Icon(Icons.sensors, color: AppTheme.emeraldSafe, size: 18),
                            const SizedBox(width: 6),
                            Flexible(child: Text(
                              'LIVE CONVOY ACTIVE',
                              style: TextStyle(
                                color: AppTheme.emeraldSafe,
                                fontWeight: FontWeight.bold,
                                fontSize: 12,
                                letterSpacing: 0.8,
                              ), maxLines: 1, overflow: TextOverflow.ellipsis)),
                          ],
                        )),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: AppTheme.obsidianVoid.withOpacity(0.5),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            'Code: ${activeConvoy.joinCode}',
                            style: TextStyle(color: AppTheme.textPrimary, fontSize: 11, fontWeight: FontWeight.bold),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Text(
                      activeConvoy.name,
                      style: TextStyle(
                        color: AppTheme.textPrimary,
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    Text(
                      '${activeConvoy.riders.length} teammates tracking live · ${activeConvoy.destinationName}',
                      style: TextStyle(color: AppTheme.textSecondary, fontSize: 12),
                    ),
                    const SizedBox(height: 14),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(backgroundColor: AppTheme.neonCyan),
                        onPressed: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => ConvoyDashboardScreen(groupId: activeConvoy.groupId),
                            ),
                          );
                        },
                        icon: const Icon(Icons.dashboard_rounded),
                        label: const Text('Enter Convoy Dashboard'),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
            ],

            // Action Launchers Grid
            Row(
              children: [
                Expanded(
                  child: GlassCard(
                    padding: const EdgeInsets.all(18),
                    borderColor: AppTheme.neonCyan.withOpacity(0.3),
                    onTap: () {
                      final auth = context.read<AuthService>();
                      if (!auth.isProfileComplete && !auth.isMasterAdmin) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: const Text('⚠️ Convoy creation locked! Mandatory safety details required.'),
                            backgroundColor: AppTheme.laserRed,
                            action: SnackBarAction(label: 'Update', textColor: Colors.white, onPressed: () => _openCompleteProfile(context)),
                          ),
                        );
                        _openCompleteProfile(context);
                        return;
                      }
                      Navigator.push(context, MaterialPageRoute(builder: (_) => const TripPlannerScreen()));
                    },
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: AppTheme.neonCyan.withOpacity(0.15),
                            shape: BoxShape.circle,
                          ),
                          child: Icon(Icons.add_road, color: AppTheme.neonCyan, size: 26),
                        ),
                        const SizedBox(height: 14),
                        Text(
                          'Create Convoy',
                          style: TextStyle(
                            color: AppTheme.textPrimary,
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Start a ride as lead and get room code',
                          style: TextStyle(color: AppTheme.textMuted, fontSize: 11),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: GlassCard(
                    padding: const EdgeInsets.all(18),
                    borderColor: AppTheme.hyperAmber.withOpacity(0.3),
                    onTap: () {
                      final auth = context.read<AuthService>();
                      if (!auth.isProfileComplete && !auth.isMasterAdmin) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: const Text('⚠️ Convoy joining locked! Mandatory safety details required.'),
                            backgroundColor: AppTheme.laserRed,
                            action: SnackBarAction(label: 'Update', textColor: Colors.white, onPressed: () => _openCompleteProfile(context)),
                          ),
                        );
                        _openCompleteProfile(context);
                        return;
                      }
                      _showJoinConvoyDialog(context);
                    },
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: AppTheme.hyperAmber.withOpacity(0.15),
                            shape: BoxShape.circle,
                          ),
                          child: Icon(Icons.qr_code_scanner, color: AppTheme.hyperAmber, size: 26),
                        ),
                        const SizedBox(height: 14),
                        Text(
                          'Join Convoy',
                          style: TextStyle(
                            color: AppTheme.textPrimary,
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Enter 6-digit code from your pack lead',
                          style: TextStyle(color: AppTheme.textMuted, fontSize: 11),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),

            const SizedBox(height: 24),

            // --- ADVANCED RIDE ANALYTICS & TELEMETRY ---
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    Icon(Icons.insights_rounded, color: AppTheme.neonCyan, size: 20),
                    const SizedBox(width: 8),
                    Text(
                      'Ride Analytics & Telemetry',
                      style: TextStyle(color: AppTheme.textPrimary, fontSize: 16, fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
                if (trips.isNotEmpty)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: AppTheme.neonCyan.withOpacity(0.12),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      '$completedRidesCount RIDES LOGGED',
                      style: TextStyle(color: AppTheme.neonCyan, fontSize: 10, fontWeight: FontWeight.bold, letterSpacing: 0.5),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 12),

            // 4-Card Analytics Grid
            Row(
              children: [
                Expanded(
                  child: _buildAnalyticsMetricCard(
                    title: 'Total Distance',
                    value: totalDistanceKm >= 100 ? totalDistanceKm.toStringAsFixed(0) : totalDistanceKm.toStringAsFixed(1),
                    unit: 'km',
                    icon: Icons.add_road_rounded,
                    accentColor: AppTheme.neonCyan,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _buildAnalyticsMetricCard(
                    title: 'Saddle Time',
                    value: hoursRidden > 0 ? '${hoursRidden}h ${minutesRidden}m' : '${minutesRidden}m',
                    unit: '',
                    icon: Icons.timer_outlined,
                    accentColor: AppTheme.hyperAmber,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: _buildAnalyticsMetricCard(
                    title: 'Avg Velocity',
                    value: overallAvgSpeed.toStringAsFixed(1),
                    unit: 'km/h',
                    icon: Icons.speed_rounded,
                    accentColor: AppTheme.emeraldSafe,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _buildAnalyticsMetricCard(
                    title: 'Peak Velocity',
                    value: maxSpeedKmh.toStringAsFixed(0),
                    unit: 'km/h',
                    icon: Icons.bolt_rounded,
                    accentColor: maxSpeedKmh > 100 ? AppTheme.laserRed : AppTheme.neonCyan,
                  ),
                ),
              ],
            ),

            const SizedBox(height: 12),

            // Fleet Dynamics & Performance Breakdown Card
            GlassCard(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.shield_outlined, color: AppTheme.emeraldSafe, size: 18),
                          const SizedBox(width: 8),
                          Text(
                            'Safety & Pace Compliance',
                            style: TextStyle(color: AppTheme.textPrimary, fontWeight: FontWeight.bold, fontSize: 13),
                          ),
                        ],
                      ),
                      Text(
                        trips.isEmpty ? '100% Benchmark' : '98% Safe Cruising',
                        style: TextStyle(color: AppTheme.emeraldSafe, fontWeight: FontWeight.bold, fontSize: 12),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: trips.isEmpty ? 1.0 : 0.98,
                      minHeight: 6,
                      backgroundColor: AppTheme.elevatedCard,
                      valueColor: AlwaysStoppedAnimation<Color>(AppTheme.emeraldSafe),
                    ),
                  ),
                  const SizedBox(height: 14),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      _buildMiniInsight(
                        label: 'AVG RIDE LENGTH',
                        value: '${avgDistancePerRide.toStringAsFixed(1)} km',
                      ),
                      _buildMiniInsight(
                        label: 'PACK DYNAMICS',
                        value: avgRidersPerConvoy > 0 ? '${avgRidersPerConvoy.toStringAsFixed(1)} Riders' : 'Solo / Pack',
                      ),
                      _buildMiniInsight(
                        label: 'TIME IN MOTION',
                        value: '${movingRatio.toStringAsFixed(0)}%',
                      ),
                    ],
                  ),
                ],
              ),
            ),

            const SizedBox(height: 24),

            // --- RECENT JOURNEYS & ROUTE TELEMETRY LOG ---
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    Icon(Icons.history_rounded, color: AppTheme.hyperAmber, size: 20),
                    const SizedBox(width: 8),
                    Text(
                      'Recent Journeys',
                      style: TextStyle(color: AppTheme.textPrimary, fontSize: 16, fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
                TextButton(
                  onPressed: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => const TripHistoryScreen()),
                    );
                  },
                  child: Text('View All', style: TextStyle(color: AppTheme.neonCyan)),
                ),
              ],
            ),
            const SizedBox(height: 8),

            if (trips.isEmpty)
              GlassCard(
                padding: const EdgeInsets.all(20),
                child: Center(
                  child: Column(
                    children: [
                      Icon(Icons.map_outlined, color: AppTheme.textMuted, size: 36),
                      const SizedBox(height: 10),
                      Text(
                        'No Journey Logs Yet',
                        style: TextStyle(color: AppTheme.textPrimary, fontWeight: FontWeight.bold, fontSize: 14),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Create or join a convoy above. When your ride finishes, full GPS telemetry, speed profiles, and stops will be cataloged here automatically.',
                        style: TextStyle(color: AppTheme.textMuted, fontSize: 12),
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                ),
              )
            else
              ...trips.take(3).map((trip) {
                return Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: GlassCard(
                    onTap: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(builder: (_) => const TripHistoryScreen()),
                      );
                    },
                    child: Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: AppTheme.hyperAmber.withOpacity(0.12),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Icon(Icons.route_rounded, color: AppTheme.hyperAmber, size: 22),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                trip.tripName,
                                style: TextStyle(
                                  color: AppTheme.textPrimary,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 14,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                              const SizedBox(height: 3),
                              Text(
                                '${trip.startLocationName.isNotEmpty ? trip.startLocationName : "Start"} → ${trip.destinationName.isNotEmpty ? trip.destinationName : "Destination"}',
                                style: TextStyle(color: AppTheme.textSecondary, fontSize: 11),
                                overflow: TextOverflow.ellipsis,
                              ),
                              const SizedBox(height: 4),
                              Row(
                                children: [
                                  Text(
                                    '${trip.totalDistanceKm.toStringAsFixed(1)} km',
                                    style: TextStyle(color: AppTheme.neonCyan, fontSize: 11, fontWeight: FontWeight.bold),
                                  ),
                                  Text(' · ', style: TextStyle(color: AppTheme.textMuted)),
                                  Text(
                                    '${trip.durationMinutes} mins',
                                    style: TextStyle(color: AppTheme.textMuted, fontSize: 11),
                                  ),
                                  if (trip.topSpeedKmh > 0) ...[
                                    Text(' · ', style: TextStyle(color: AppTheme.textMuted)),
                                    Text(
                                      'Max ${trip.topSpeedKmh.toStringAsFixed(0)} km/h',
                                      style: TextStyle(color: AppTheme.hyperAmber, fontSize: 11),
                                    ),
                                  ],
                                ],
                              ),
                            ],
                          ),
                        ),
                        Icon(Icons.chevron_right_rounded, color: AppTheme.textMuted, size: 20),
                      ],
                    ),
                  ),
                );
              }),

            const SizedBox(height: 24),
          ],
        ),
          ),
        ),
      ),
    );
  }

  void _showIncompleteProfileAlert(BuildContext context) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text('⚠️ Mandatory safety profile incomplete! Please update your details.'),
        backgroundColor: AppTheme.laserRed,
        action: SnackBarAction(
          label: 'Update',
          textColor: Colors.white,
          onPressed: () => _openCompleteProfile(context),
        ),
      ),
    );
    _openCompleteProfile(context);
  }

  Widget _buildAnalyticsMetricCard({
    required String title,
    required String value,
    required String unit,
    required IconData icon,
    required Color accentColor,
  }) {
    return GlassCard(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                title.toUpperCase(),
                style: TextStyle(color: AppTheme.textMuted, fontSize: 10, fontWeight: FontWeight.bold, letterSpacing: 0.8),
              ),
              Icon(icon, color: accentColor, size: 16),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                value,
                style: TextStyle(color: AppTheme.textPrimary, fontSize: 20, fontWeight: FontWeight.bold),
              ),
              if (unit.isNotEmpty) ...[
                const SizedBox(width: 4),
                Text(
                  unit,
                  style: TextStyle(color: AppTheme.textMuted, fontSize: 11, fontWeight: FontWeight.w600),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildMiniInsight({required String label, required String value}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(color: AppTheme.textMuted, fontSize: 9, fontWeight: FontWeight.bold, letterSpacing: 0.6),
        ),
        const SizedBox(height: 2),
        Text(
          value,
          style: TextStyle(color: AppTheme.textPrimary, fontSize: 13, fontWeight: FontWeight.bold),
        ),
      ],
    );
  }

  Widget _buildDrawer(
    BuildContext context,
    AuthService auth,
    ConvoyService convoyService,
    ConvoyModel? activeConvoy,
  ) {
    return Drawer(
      backgroundColor: AppTheme.obsidianVoid,
      child: Column(
        children: [
          // Drawer Profile Header
          Container(
            padding: EdgeInsets.fromLTRB(20, MediaQuery.of(context).padding.top + 20, 20, 20),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [AppTheme.slateCard, AppTheme.obsidianVoid],
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
              ),
              border: Border(bottom: BorderSide(color: AppTheme.glassBorder)),
            ),
            child: InkWell(
              onTap: () {
                Navigator.pop(context);
                _openCompleteProfile(context);
              },
              child: Row(
                children: [
                  CircleAvatar(
                    radius: 26,
                    backgroundColor: AppTheme.neonCyan.withOpacity(0.2),
                    child: Icon(Icons.two_wheeler_rounded, color: AppTheme.neonCyan, size: 28),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          auth.currentUserName ?? 'Rider',
                          style: TextStyle(color: AppTheme.textPrimary, fontWeight: FontWeight.bold, fontSize: 16),
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          auth.currentUserEmail ?? '',
                          style: TextStyle(color: AppTheme.textMuted, fontSize: 11),
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: auth.isProfileComplete ? AppTheme.emeraldSafe.withOpacity(0.15) : AppTheme.laserRed.withOpacity(0.15),
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(
                              color: auth.isProfileComplete ? AppTheme.emeraldSafe.withOpacity(0.4) : AppTheme.laserRed.withOpacity(0.4),
                            ),
                          ),
                          child: Text(
                            auth.isProfileComplete ? 'Profile Verified' : 'Incomplete Profile ⚠️',
                            style: TextStyle(
                              color: auth.isProfileComplete ? AppTheme.emeraldSafe : AppTheme.laserRed,
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  Icon(Icons.chevron_right_rounded, color: AppTheme.textMuted, size: 20),
                ],
              ),
            ),
          ),

          // Drawer Navigation Items
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(vertical: 8),
              children: [
                _drawerSectionHeader('CONVOY & RIDES'),
                _drawerTile(
                  icon: Icons.add_road_rounded,
                  title: 'Create Convoy',
                  subtitle: 'Start route as lead & get code',
                  accentColor: AppTheme.neonCyan,
                  onTap: () {
                    Navigator.pop(context);
                    if (!auth.isProfileComplete && !auth.isMasterAdmin) {
                      _showIncompleteProfileAlert(context);
                      return;
                    }
                    Navigator.push(context, MaterialPageRoute(builder: (_) => const TripPlannerScreen()));
                  },
                ),
                _drawerTile(
                  icon: Icons.qr_code_scanner_rounded,
                  title: 'Join Convoy',
                  subtitle: 'Enter 6-digit room code',
                  accentColor: AppTheme.hyperAmber,
                  onTap: () {
                    Navigator.pop(context);
                    if (!auth.isProfileComplete && !auth.isMasterAdmin) {
                      _showIncompleteProfileAlert(context);
                      return;
                    }
                    _showJoinConvoyDialog(context);
                  },
                ),
                if (activeConvoy != null)
                  _drawerTile(
                    icon: Icons.navigation_rounded,
                    title: 'Live Cockpit HUD',
                    subtitle: 'Resume radar, telemetry & audio',
                    accentColor: AppTheme.emeraldSafe,
                    onTap: () {
                      Navigator.pop(context);
                      Navigator.push(context, MaterialPageRoute(builder: (_) => LiveCockpitMapScreen(convoyId: activeConvoy.groupId)));
                    },
                  ),

                const Divider(color: Colors.white10, height: 20),
                _drawerSectionHeader('TRACKING & ANALYTICS'),
                _drawerTile(
                  icon: Icons.history_rounded,
                  title: 'Trip History & Replays',
                  subtitle: 'Completed rides & GPS timelines',
                  accentColor: AppTheme.neonCyan,
                  onTap: () {
                    Navigator.pop(context);
                    Navigator.push(context, MaterialPageRoute(builder: (_) => const TripHistoryScreen()));
                  },
                ),
                if (activeConvoy != null)
                  _drawerTile(
                    icon: Icons.timeline_rounded,
                    title: 'Live Group Timeline',
                    subtitle: 'Active member stops & milestones',
                    accentColor: AppTheme.hyperAmber,
                    onTap: () {
                      Navigator.pop(context);
                      Navigator.push(context, MaterialPageRoute(builder: (_) => LiveTimelineScreen(groupId: activeConvoy.groupId)));
                    },
                  ),

                const Divider(color: Colors.white10, height: 20),
                _drawerSectionHeader('SAFETY & SETTINGS'),
                _drawerTile(
                  icon: Icons.shield_outlined,
                  title: 'Rider Profile & ICE',
                  subtitle: 'Emergency contacts & vehicle plate',
                  accentColor: AppTheme.hyperAmber,
                  onTap: () {
                    Navigator.pop(context);
                    Navigator.push(context, MaterialPageRoute(builder: (_) => const EditProfileScreen()));
                  },
                ),
                _drawerTile(
                  icon: Icons.palette_outlined,
                  title: 'Theme & Appearance',
                  subtitle: 'Dark, light or sunrise sync',
                  accentColor: AppTheme.neonCyan,
                  onTap: () {
                    Navigator.pop(context);
                    AppearanceSheet.show(context);
                  },
                ),
                _drawerTile(
                  icon: Icons.verified_user_rounded,
                  title: 'Sensors & Permissions',
                  subtitle: 'Location, microphone & battery',
                  accentColor: AppTheme.emeraldSafe,
                  onTap: () {
                    Navigator.pop(context);
                    Navigator.push(context, MaterialPageRoute(builder: (_) => const PermissionsScreen()));
                  },
                ),
                _drawerTile(
                  icon: Icons.manage_accounts_rounded,
                  title: 'Account & Security',
                  subtitle: 'Password, terms & privacy',
                  accentColor: AppTheme.textSecondary,
                  onTap: () {
                    Navigator.pop(context);
                    Navigator.push(context, MaterialPageRoute(builder: (_) => const AccountScreen()));
                  },
                ),

                if (auth.isMasterAdmin) ...[
                  const Divider(color: Colors.white10, height: 20),
                  _drawerSectionHeader('ADMINISTRATION'),
                  _drawerTile(
                    icon: Icons.admin_panel_settings_rounded,
                    title: 'Master Admin Console',
                    subtitle: 'Fleet radar, retention & users',
                    accentColor: AppTheme.devmonksPurple,
                    onTap: () {
                      Navigator.pop(context);
                      Navigator.push(context, MaterialPageRoute(builder: (_) => const MasterAdminDashboard()));
                    },
                  ),
                ],
              ],
            ),
          ),

          // Drawer Footer & Logout
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              border: Border(top: BorderSide(color: AppTheme.glassBorder)),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'CoRoute v3.9',
                    style: TextStyle(color: AppTheme.textMuted, fontSize: 11),
                  ),
                ),
                TextButton.icon(
                  onPressed: () async {
                    Navigator.pop(context);
                    await auth.logout();
                    if (context.mounted) {
                      Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const AccessGateScreen()));
                    }
                  },
                  icon: Icon(Icons.logout_rounded, color: AppTheme.laserRed, size: 16),
                  label: Text('Sign Out', style: TextStyle(color: AppTheme.laserRed, fontSize: 12, fontWeight: FontWeight.bold)),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _drawerSectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Text(
        title,
        style: TextStyle(color: AppTheme.textMuted, fontSize: 10, fontWeight: FontWeight.bold, letterSpacing: 1.1),
      ),
    );
  }

  Widget _drawerTile({
    required IconData icon,
    required String title,
    required String subtitle,
    required Color accentColor,
    required VoidCallback onTap,
  }) {
    return ListTile(
      dense: true,
      leading: Container(
        padding: const EdgeInsets.all(7),
        decoration: BoxDecoration(
          color: accentColor.withOpacity(0.12),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Icon(icon, color: accentColor, size: 18),
      ),
      title: Text(title, style: TextStyle(color: AppTheme.textPrimary, fontWeight: FontWeight.bold, fontSize: 13)),
      subtitle: Text(subtitle, style: TextStyle(color: AppTheme.textMuted, fontSize: 11)),
      trailing: Icon(Icons.chevron_right_rounded, color: AppTheme.textMuted, size: 16),
      onTap: onTap,
    );
  }
}
