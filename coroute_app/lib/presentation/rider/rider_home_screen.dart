import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:provider/provider.dart';
import '../../core/constants/app_constants.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/devmonks_branding.dart';
import '../../core/widgets/glass_card.dart';
import '../../data/models/convoy_model.dart';
import '../../data/models/rider_model.dart';
import '../../data/services/api_client.dart';
import '../../data/services/auth_service.dart';
import '../../data/services/convoy_service.dart';
import '../../data/services/trip_storage_service.dart';
import '../../data/services/routing_service.dart';
import '../account/account_screen.dart';
import '../onboarding/permissions_screen.dart';
import 'convoy_dashboard_screen.dart';
import 'trip_history_screen.dart';

class RiderHomeScreen extends StatefulWidget {
  const RiderHomeScreen({super.key});

  @override
  State<RiderHomeScreen> createState() => _RiderHomeScreenState();
}

class _RiderHomeScreenState extends State<RiderHomeScreen> {
  final _joinCodeController = TextEditingController();
  final _createNameController = TextEditingController();
  final _destinationController = TextEditingController();
  ConvoyService? _convoyService;
  bool _joinDialogOpen = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _convoyService = context.read<ConvoyService>();
      _convoyService!.addListener(_onConvoyChanged);
      _onConvoyChanged();
    });
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
    _createNameController.dispose();
    _destinationController.dispose();
    super.dispose();
  }

  void _showCreateConvoyDialog(BuildContext context) {
    List<PlaceSuggestion> suggestions = [];
    double selectedLat = 0.0;
    double selectedLng = 0.0;
    RouteDetails? routeDetails;
    bool isSearching = false;
    bool isRouting = false;

    showDialog(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (dialogCtx, setDialogState) {
            return AlertDialog(
              backgroundColor: AppTheme.slateCard,
              title: const Row(
                children: [
                  Icon(Icons.add_road, color: AppTheme.neonCyan),
                  SizedBox(width: 8),
                  Text('Create Convoy', style: TextStyle(color: Colors.white, fontSize: 18)),
                ],
              ),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Convoy Name', style: TextStyle(color: AppTheme.textSecondary, fontSize: 12)),
                    const SizedBox(height: 6),
                    TextField(
                      controller: _createNameController,
                      style: const TextStyle(color: Colors.white),
                      decoration: const InputDecoration(hintText: 'e.g. Coastal Dawn Run'),
                    ),
                    const SizedBox(height: 14),
                    const Text('Target Destination / Waypoint', style: TextStyle(color: AppTheme.textSecondary, fontSize: 12)),
                    const SizedBox(height: 6),
                    TextField(
                      controller: _destinationController,
                      style: const TextStyle(color: Colors.white),
                      decoration: InputDecoration(
                        hintText: 'Search city, landmark, or cafe...',
                        suffixIcon: isSearching
                            ? const Padding(
                                padding: EdgeInsets.all(12),
                                child: SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(strokeWidth: 2, color: AppTheme.neonCyan),
                                ),
                              )
                            : const Icon(Icons.search, color: AppTheme.neonCyan, size: 20),
                      ),
                      onChanged: (val) async {
                        if (val.trim().length >= 3) {
                          setDialogState(() => isSearching = true);
                          final results = await RoutingService.searchPlaces(val);
                          setDialogState(() {
                            suggestions = results;
                            isSearching = false;
                          });
                        } else {
                          setDialogState(() => suggestions = []);
                        }
                      },
                    ),

                    if (suggestions.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Container(
                        constraints: const BoxConstraints(maxHeight: 180),
                        decoration: BoxDecoration(
                          color: AppTheme.elevatedCard,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: AppTheme.glassBorder),
                        ),
                        child: ListView.separated(
                          shrinkWrap: true,
                          itemCount: suggestions.length,
                          separatorBuilder: (_, _) => const Divider(color: AppTheme.subtleBorder, height: 1),
                          itemBuilder: (c, idx) {
                            final place = suggestions[idx];
                            return ListTile(
                              dense: true,
                              leading: const Icon(Icons.location_on, color: AppTheme.laserRed, size: 18),
                              title: Text(
                                place.displayName,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(color: Colors.white, fontSize: 12),
                              ),
                              onTap: () async {
                                final shortName = place.displayName.split(',').take(2).join(',');
                                _destinationController.text = shortName;
                                selectedLat = place.lat;
                                selectedLng = place.lng;
                                suggestions = [];
                                isRouting = true;
                                setDialogState(() {});

                                // Compute OSRM route from current device GPS (fast 2s max)
                                Position? pos = await Geolocator.getLastKnownPosition();
                                if (pos == null) {
                                  try {
                                    pos = await Geolocator.getCurrentPosition(
                                      locationSettings: const LocationSettings(
                                        accuracy: LocationAccuracy.medium,
                                        timeLimit: Duration(seconds: 2),
                                      ),
                                    );
                                  } catch (_) {}
                                }

                                final startLat = pos?.latitude ?? selectedLat;
                                final startLng = pos?.longitude ?? selectedLng;

                                final route = await RoutingService.fetchRoute(
                                  startLat: startLat,
                                  startLng: startLng,
                                  endLat: selectedLat,
                                  endLng: selectedLng,
                                );
                                setDialogState(() {
                                  routeDetails = route;
                                  isRouting = false;
                                });
                              },
                            );
                          },
                        ),
                      ),
                    ],

                    if (isRouting) ...[
                      const SizedBox(height: 10),
                      const Row(
                        children: [
                          SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: AppTheme.hyperAmber)),
                          SizedBox(width: 8),
                          Text('Computing OSRM driving route...', style: TextStyle(color: AppTheme.hyperAmber, fontSize: 11)),
                        ],
                      ),
                    ],

                    if (routeDetails != null) ...[
                      const SizedBox(height: 10),
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: AppTheme.emeraldSafe.withOpacity(0.12),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: AppTheme.emeraldSafe.withOpacity(0.4)),
                        ),
                        child: Row(
                          children: [
                            const Icon(Icons.directions, color: AppTheme.emeraldSafe, size: 18),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                'Route: ${routeDetails!.distanceKm} km · ${routeDetails!.durationMinutes.toInt()} mins',
                                style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('Cancel', style: TextStyle(color: AppTheme.textMuted)),
                ),
                ElevatedButton(
                  onPressed: () async {
                    if (_createNameController.text.trim().isEmpty) return;
                    final auth = context.read<AuthService>();
                    final convoyService = context.read<ConvoyService>();
                    if (!await PermissionsScreen.ensure(context)) return;
                    if (!ctx.mounted) return;

                    final breadcrumbs = routeDetails?.polyline
                            .map((p) => {'lat': p.latitude, 'lng': p.longitude})
                            .toList() ??
                        [];

                    final ConvoyModel newConvoy;
                    try {
                      newConvoy = await convoyService.createConvoy(
                        name: _createNameController.text,
                        creatorId: auth.currentUserId ?? '',
                        creatorName: auth.currentUserName ?? 'Lead Rider',
                        destination: _destinationController.text,
                        destLat: selectedLat,
                        destLng: selectedLng,
                        vehicleType: auth.vehicleType ?? 'Motorcycle',
                        vehicleNo: auth.vehicleNo ?? '',
                        phone: auth.phone ?? '',
                        routeBreadcrumbs: breadcrumbs,
                      );
                    } catch (e) {
                      if (!ctx.mounted) return;
                      ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(
                        content: Text(e is ApiException ? e.message : 'Could not create the convoy. Check your connection.'),
                        backgroundColor: AppTheme.laserRed,
                      ));
                      return;
                    }

                    if (!ctx.mounted) return;
                    Navigator.pop(ctx);
                    Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => ConvoyDashboardScreen(groupId: newConvoy.groupId)),
                    );
                  },
                  child: const Text('Launch Convoy'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  void _showJoinConvoyDialog(BuildContext context) {
    _joinDialogOpen = true;
    showDialog(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          backgroundColor: AppTheme.slateCard,
          title: const Row(
            children: [
              Icon(Icons.qr_code_scanner, color: AppTheme.hyperAmber),
              SizedBox(width: 8),
              Text('Join with Code', style: TextStyle(color: Colors.white, fontSize: 18)),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Enter the 6-character room code shared by your convoy lead.',
                style: TextStyle(color: AppTheme.textSecondary, fontSize: 12),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: _joinCodeController,
                style: const TextStyle(color: Colors.white, letterSpacing: 3, fontWeight: FontWeight.bold),
                textCapitalization: TextCapitalization.characters,
                decoration: const InputDecoration(
                  hintText: 'e.g. WST900',
                  prefixIcon: Icon(Icons.key, color: AppTheme.hyperAmber),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel', style: TextStyle(color: AppTheme.textMuted)),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: AppTheme.hyperAmber),
              onPressed: () async {
                final code = _joinCodeController.text.trim();
                final auth = context.read<AuthService>();
                final convoyService = context.read<ConvoyService>();
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

  void _showEditProfileDialog(BuildContext context, AuthService auth) {
    final phoneCtrl = TextEditingController(text: auth.phone ?? '');
    final vehicleNoCtrl = TextEditingController(text: auth.vehicleNo ?? '');
    final emergencyNameCtrl = TextEditingController(text: auth.emergencyContactName ?? '');
    final emergencyPhoneCtrl = TextEditingController(text: auth.emergencyContact ?? '');
    String vehicleType = auth.vehicleType ?? 'Motorcycle (Adv)';

    final vehicleTypes = [
      'Motorcycle (Adv)',
      'Motorcycle (Cruiser)',
      'Motorcycle (Sport)',
      'Motorcycle (Commuter)',
      'Scooter / Maxi',
      'Support Car / SUV',
    ];

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          backgroundColor: AppTheme.slateCard,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Row(
            children: [
              const Icon(Icons.manage_accounts_rounded, color: AppTheme.neonCyan),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  '${auth.currentUserName} Profile',
                  style: const TextStyle(color: Colors.white, fontSize: 16),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('PHONE NUMBER', style: TextStyle(color: AppTheme.textSecondary, fontSize: 10, fontWeight: FontWeight.bold)),
                const SizedBox(height: 4),
                TextField(
                  controller: phoneCtrl,
                  keyboardType: TextInputType.phone,
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                  decoration: InputDecoration(
                    hintText: 'Your mobile number',
                    hintStyle: const TextStyle(color: AppTheme.textMuted),
                    filled: true,
                    fillColor: AppTheme.elevatedCard,
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                ),
                const SizedBox(height: 12),
                const Text('VEHICLE TYPE', style: TextStyle(color: AppTheme.textSecondary, fontSize: 10, fontWeight: FontWeight.bold)),
                const SizedBox(height: 4),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  decoration: BoxDecoration(
                    color: AppTheme.elevatedCard,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: AppTheme.glassBorder),
                  ),
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<String>(
                      value: vehicleTypes.contains(vehicleType) ? vehicleType : vehicleTypes.first,
                      dropdownColor: AppTheme.slateCard,
                      isExpanded: true,
                      style: const TextStyle(color: Colors.white, fontSize: 12),
                      items: vehicleTypes.map((v) => DropdownMenuItem(value: v, child: Text(v))).toList(),
                      onChanged: (val) {
                        if (val != null) setDialogState(() => vehicleType = val);
                      },
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                const Text('VEHICLE REGISTRATION NUMBER', style: TextStyle(color: AppTheme.textSecondary, fontSize: 10, fontWeight: FontWeight.bold)),
                const SizedBox(height: 4),
                TextField(
                  controller: vehicleNoCtrl,
                  textCapitalization: TextCapitalization.characters,
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                  decoration: InputDecoration(
                    hintText: 'e.g. KA 01 AB 1234',
                    hintStyle: const TextStyle(color: AppTheme.textMuted),
                    filled: true,
                    fillColor: AppTheme.elevatedCard,
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                ),
                const SizedBox(height: 12),
                const Text('EMERGENCY (ICE) CONTACT NAME', style: TextStyle(color: AppTheme.hyperAmber, fontSize: 10, fontWeight: FontWeight.bold)),
                const SizedBox(height: 4),
                TextField(
                  controller: emergencyNameCtrl,
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                  decoration: InputDecoration(
                    hintText: 'Contact Name (e.g. Spouse / Brother)',
                    hintStyle: const TextStyle(color: AppTheme.textMuted),
                    filled: true,
                    fillColor: AppTheme.elevatedCard,
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                ),
                const SizedBox(height: 12),
                const Text('EMERGENCY (ICE) PHONE NUMBER', style: TextStyle(color: AppTheme.hyperAmber, fontSize: 10, fontWeight: FontWeight.bold)),
                const SizedBox(height: 4),
                TextField(
                  controller: emergencyPhoneCtrl,
                  keyboardType: TextInputType.phone,
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                  decoration: InputDecoration(
                    hintText: 'Emergency phone number',
                    hintStyle: const TextStyle(color: AppTheme.textMuted),
                    filled: true,
                    fillColor: AppTheme.elevatedCard,
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel', style: TextStyle(color: AppTheme.textMuted)),
            ),
            ElevatedButton(
              onPressed: () async {
                await auth.updateProfile(
                  phone: phoneCtrl.text,
                  vehicleType: vehicleType,
                  vehicleNo: vehicleNoCtrl.text,
                  emergencyContact: emergencyPhoneCtrl.text,
                  emergencyContactName: emergencyNameCtrl.text,
                );
                if (ctx.mounted) {
                  Navigator.pop(ctx);
                }
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Rider profile updated!'), backgroundColor: AppTheme.emeraldSafe),
                  );
                }
              },
              style: ElevatedButton.styleFrom(backgroundColor: AppTheme.neonCyan, foregroundColor: Colors.black),
              child: const Text('Save Profile'),
            ),
          ],
        ),
      ),
    );
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
              decoration: const BoxDecoration(
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
            icon: const Icon(Icons.history, color: AppTheme.neonCyan),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const TripHistoryScreen()),
              );
            },
          ),
          IconButton(
            tooltip: 'Account & security',
            icon: const Icon(Icons.manage_accounts_rounded, color: AppTheme.textMuted),
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
              onTap: () => _showEditProfileDialog(context, auth),
              child: GlassCard(
                child: Row(
                  children: [
                    CircleAvatar(
                      radius: 22,
                      backgroundColor: AppTheme.neonCyan.withOpacity(0.18),
                      child: const Icon(Icons.person, color: AppTheme.neonCyan, size: 26),
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
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 16,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 6),
                              const Icon(Icons.edit_note_rounded, color: AppTheme.neonCyan, size: 18),
                            ],
                          ),
                          Text(
                            '${auth.vehicleType ?? 'Motorcycle'}${auth.vehicleNo != null && auth.vehicleNo!.isNotEmpty ? " · ${auth.vehicleNo}" : ""} · ${auth.phone != null && auth.phone!.isNotEmpty ? auth.phone : "Tap to edit profile"}',
                            style: const TextStyle(color: AppTheme.textSecondary, fontSize: 11),
                          ),
                        ],
                      ),
                    ),
                    const DevMonksBadge(isCompact: true),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 20),

            // Active Convoy Quick Resume Banner (if in session)
            if (activeConvoy != null) ...[
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [Color(0xFF0F2B48), Color(0xFF161F2E)],
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
                        Row(
                          children: [
                            const Icon(Icons.sensors, color: AppTheme.emeraldSafe, size: 18),
                            const SizedBox(width: 6),
                            const Text(
                              'LIVE CONVOY ACTIVE',
                              style: TextStyle(
                                color: AppTheme.emeraldSafe,
                                fontWeight: FontWeight.bold,
                                fontSize: 12,
                                letterSpacing: 0.8,
                              ),
                            ),
                          ],
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: Colors.black.withOpacity(0.4),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            'Code: ${activeConvoy.joinCode}',
                            style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Text(
                      activeConvoy.name,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    Text(
                      '${activeConvoy.riders.length} teammates tracking live · ${activeConvoy.destinationName}',
                      style: const TextStyle(color: AppTheme.textSecondary, fontSize: 12),
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
                    onTap: () => _showCreateConvoyDialog(context),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: AppTheme.neonCyan.withOpacity(0.15),
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(Icons.add_road, color: AppTheme.neonCyan, size: 26),
                        ),
                        const SizedBox(height: 14),
                        const Text(
                          'Create Convoy',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 4),
                        const Text(
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
                    onTap: () => _showJoinConvoyDialog(context),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: AppTheme.hyperAmber.withOpacity(0.15),
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(Icons.qr_code_scanner, color: AppTheme.hyperAmber, size: 26),
                        ),
                        const SizedBox(height: 14),
                        const Text(
                          'Join Convoy',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 4),
                        const Text(
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
                const Text(
                  'Recent Journeys',
                  style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
                ),
                TextButton(
                  onPressed: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => const TripHistoryScreen()),
                    );
                  },
                  child: const Text('View All', style: TextStyle(color: AppTheme.neonCyan)),
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
                        child: const Icon(Icons.route, color: AppTheme.hyperAmber, size: 20),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              trip.tripName,
                              style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.bold,
                                fontSize: 13,
                              ),
                            ),
                            Text(
                              '${trip.totalDistanceKm} km · ${trip.durationMinutes} mins · ${trip.riderCount} riders',
                              style: const TextStyle(color: AppTheme.textMuted, fontSize: 11),
                            ),
                          ],
                        ),
                      ),
                      const Icon(Icons.chevron_right, color: AppTheme.textMuted, size: 18),
                    ],
                  ),
                ),
              );
            }),

            const SizedBox(height: 30),
            const Center(child: DevMonksBadge()),
          ],
        ),
          ),
        ),
      ),
    );
  }
}
