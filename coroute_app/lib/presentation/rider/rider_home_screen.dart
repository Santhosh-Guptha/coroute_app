import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:provider/provider.dart';
import '../../core/constants/app_constants.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/glass_card.dart';
import '../../data/models/rider_model.dart';
import '../../data/services/auth_service.dart';
import '../../data/services/convoy_service.dart';
import '../../data/services/trip_storage_service.dart';
import '../account/account_screen.dart';
import '../onboarding/permissions_screen.dart';
import 'convoy_dashboard_screen.dart';
import 'trip_history_screen.dart';
import '../trip_planner/trip_planner_screen.dart';
import '../auth/complete_profile_screen.dart';

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

    return Scaffold(
      backgroundColor: AppTheme.obsidianVoid,
      appBar: AppBar(
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
            icon: Icon(Icons.history, color: AppTheme.neonCyan),
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

            // Recent Journeys Preview
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Recent Journeys',
                  style: TextStyle(color: AppTheme.textPrimary, fontSize: 16, fontWeight: FontWeight.bold),
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

            ...tripStorage.trips.take(2).map((trip) {
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
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: AppTheme.elevatedCard,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Icon(Icons.route, color: AppTheme.hyperAmber, size: 20),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              trip.tripName,
                              style: TextStyle(
                                color: AppTheme.textPrimary,
                                fontWeight: FontWeight.bold,
                                fontSize: 13,
                              ),
                            ),
                            Text(
                              '${trip.totalDistanceKm} km · ${trip.durationMinutes} mins · ${trip.riderCount} riders',
                              style: TextStyle(color: AppTheme.textMuted, fontSize: 11),
                            ),
                          ],
                        ),
                      ),
                      Icon(Icons.chevron_right, color: AppTheme.textMuted, size: 18),
                    ],
                  ),
                ),
              );
            }),

            const SizedBox(height: 20),
          ],
        ),
          ),
        ),
      ),
    );
  }
}
