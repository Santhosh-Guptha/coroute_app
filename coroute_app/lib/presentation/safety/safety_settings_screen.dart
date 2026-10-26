import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/ui/ui.dart';
import '../../data/services/auth_service.dart';
import '../../data/services/biometric_safety_bridge.dart';
import '../../data/services/ble_remote_service.dart';
import '../../data/services/helmet_voice_service.dart';
import '../../data/services/permissions_service.dart';
import '../../data/services/settings_service.dart';
import '../../data/services/smart_airbag_bridge_service.dart';

/// Minimal, distraction-free Rider Safety Settings Screen.
///
/// Ergonomically crafted for motorcycle riders with thick gloves:
/// - 4 cohesive card sections (Safety Shield, Navigation & Tunnels, Audio & Controls, Rider Identity)
/// - Plain-English, 1-line descriptions with zero technical jargon
/// - Deep dark theme (#0B0D0E) with subtle rounded cards (#14171A)
/// - Oversized 52dp+ touch targets for effortless gloved thumb interaction
/// - Instant glanceable status badges (Connected, Ready, Off)
class SafetySettingsScreen extends StatefulWidget {
  final Future<bool> Function(String key)? requestPermission;
  const SafetySettingsScreen({super.key, this.requestPermission});

  static Future<void> show(BuildContext context) => showAppSheet<void>(
        context,
        isScrollControlled: true,
        builder: (_) => const SafetySettingsScreen(),
      );

  @override
  State<SafetySettingsScreen> createState() => _SafetySettingsScreenState();
}

class _SafetySettingsScreenState extends State<SafetySettingsScreen> {
  // Theme constants
  static const Color _bg = Color(0xFF0B0D0E);
  static const Color _card = Color(0xFF14171A);
  static const Color _border = Color(0xFF22282F);
  static const Color _tealAccent = Color(0xFF5CCAD3);
  static const Color _textPrimary = Color(0xFFF2F6F8);
  static const Color _textMuted = Color(0xFF9BAAB5);

  Future<void> _handleSmsToggle(SettingsService s, bool enable) async {
    if (!enable) {
      await s.setSmsFallback(false);
      return;
    }
    final req = widget.requestPermission ?? PermissionsService.request;
    final granted = await req('sms');
    if (!mounted) return;
    if (granted) {
      await s.setSmsFallback(true);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('SMS permission required for emergency text dispatch.'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  void _openRiderIdentitySheet(BuildContext context, AuthService? auth) {
    if (auth == null) return;
    final nameCtrl = TextEditingController(text: auth.currentUserName ?? '');
    String selectedBlood = auth.bloodGroup.isNotEmpty ? auth.bloodGroup : 'O+';
    final notesCtrl = TextEditingController(text: auth.medicalNotes);

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: _bg,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) {
          final bottomInset = MediaQuery.of(ctx).viewInsets.bottom;
          const bloodGroups = ['O+', 'O-', 'A+', 'A-', 'B+', 'B-', 'AB+', 'AB-'];

          return Padding(
            padding: EdgeInsets.fromLTRB(20, 20, 20, 20 + bottomInset),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        'Rider Identity & Vitals',
                        style: TextStyle(
                          color: _textPrimary,
                          fontSize: 18,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close_rounded, color: _textMuted),
                        onPressed: () => Navigator.pop(ctx),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    'CALLSIGN',
                    style: TextStyle(
                      color: _tealAccent,
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.8,
                    ),
                  ),
                  const SizedBox(height: 6),
                  TextField(
                    controller: nameCtrl,
                    style: const TextStyle(color: _textPrimary, fontSize: 16),
                    decoration: InputDecoration(
                      filled: true,
                      fillColor: _card,
                      hintText: 'e.g. Maverick, Falcon',
                      hintStyle: const TextStyle(color: _textMuted),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: const BorderSide(color: _border),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: const BorderSide(color: _border),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: const BorderSide(color: _tealAccent, width: 1.5),
                      ),
                    ),
                  ),
                  const SizedBox(height: 18),
                  const Text(
                    'BLOOD GROUP',
                    style: TextStyle(
                      color: _tealAccent,
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.8,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: bloodGroups.map((bg) {
                      final isSelected = selectedBlood == bg;
                      return ChoiceChip(
                        label: Text(
                          bg,
                          style: TextStyle(
                            color: isSelected ? Colors.black : _textPrimary,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        selected: isSelected,
                        selectedColor: _tealAccent,
                        backgroundColor: _card,
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        onSelected: (val) {
                          if (val) setSheetState(() => selectedBlood = bg);
                        },
                      );
                    }).toList(),
                  ),
                  const SizedBox(height: 18),
                  const Text(
                    'MEDICAL NOTES / ALLERGIES (OPTIONAL)',
                    style: TextStyle(
                      color: _tealAccent,
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.8,
                    ),
                  ),
                  const SizedBox(height: 6),
                  TextField(
                    controller: notesCtrl,
                    style: const TextStyle(color: _textPrimary, fontSize: 15),
                    decoration: InputDecoration(
                      filled: true,
                      fillColor: _card,
                      hintText: 'e.g. Penicillin allergy, Diabetes',
                      hintStyle: const TextStyle(color: _textMuted),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: const BorderSide(color: _border),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: const BorderSide(color: _border),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: const BorderSide(color: _tealAccent, width: 1.5),
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                  SizedBox(
                    height: 52,
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _tealAccent,
                        foregroundColor: Colors.black,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      onPressed: () async {
                        final navigator = Navigator.of(ctx);
                        final messenger = ScaffoldMessenger.of(context);
                        try {
                          await auth.updateProfile(
                            phone: auth.phone ?? '',
                            vehicleType: auth.vehicleType ?? 'Motorcycle',
                            vehicleNo: auth.vehicleNo ?? '',
                            emergencyContact: auth.emergencyContact ?? '',
                            emergencyContactName: auth.emergencyContactName ?? '',
                            name: nameCtrl.text.trim().isNotEmpty ? nameCtrl.text.trim() : null,
                            bloodGroup: selectedBlood,
                            medicalNotes: notesCtrl.text.trim(),
                          );
                          navigator.pop();
                          if (mounted) {
                            messenger.showSnackBar(
                              const SnackBar(
                                content: Text('Rider profile updated.'),
                                behavior: SnackBarBehavior.floating,
                              ),
                            );
                          }
                        } catch (e) {
                          if (mounted) {
                            messenger.showSnackBar(
                              SnackBar(
                                content: Text('Failed to update profile: $e'),
                                behavior: SnackBarBehavior.floating,
                                backgroundColor: Colors.redAccent,
                              ),
                            );
                          }
                        }
                      },
                      child: const Text(
                        'Save Identity',
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  void _openEmergencyContactsSheet(BuildContext context, AuthService? auth, SettingsService s) {
    if (auth == null) return;
    final nameCtrl = TextEditingController(text: auth.emergencyContactName ?? '');
    final phoneCtrl = TextEditingController(text: auth.emergencyContact ?? '');

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: _bg,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) {
          final bottomInset = MediaQuery.of(ctx).viewInsets.bottom;

          return Padding(
            padding: EdgeInsets.fromLTRB(20, 20, 20, 20 + bottomInset),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        'Emergency Contacts',
                        style: TextStyle(
                          color: _textPrimary,
                          fontSize: 18,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close_rounded, color: _textMuted),
                        onPressed: () => Navigator.pop(ctx),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Dispatches automatic crash alerts with GPS coordinates via SMS and WhatsApp.',
                    style: TextStyle(color: _textMuted, fontSize: 13, height: 1.4),
                  ),
                  const SizedBox(height: 18),
                  const Text(
                    'CONTACT NAME',
                    style: TextStyle(
                      color: _tealAccent,
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.8,
                    ),
                  ),
                  const SizedBox(height: 6),
                  TextField(
                    controller: nameCtrl,
                    style: const TextStyle(color: _textPrimary, fontSize: 16),
                    decoration: InputDecoration(
                      filled: true,
                      fillColor: _card,
                      hintText: 'e.g. Partner, Parent, Road Mate',
                      hintStyle: const TextStyle(color: _textMuted),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: const BorderSide(color: _border),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: const BorderSide(color: _border),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: const BorderSide(color: _tealAccent, width: 1.5),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    'PHONE NUMBER (WITH COUNTRY CODE)',
                    style: TextStyle(
                      color: _tealAccent,
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.8,
                    ),
                  ),
                  const SizedBox(height: 6),
                  TextField(
                    controller: phoneCtrl,
                    keyboardType: TextInputType.phone,
                    style: const TextStyle(color: _textPrimary, fontSize: 16),
                    decoration: InputDecoration(
                      filled: true,
                      fillColor: _card,
                      hintText: 'e.g. +91 98765 43210',
                      hintStyle: const TextStyle(color: _textMuted),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: const BorderSide(color: _border),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: const BorderSide(color: _border),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: const BorderSide(color: _tealAccent, width: 1.5),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    value: s.smsFallback,
                    activeColor: _tealAccent,
                    title: const Text(
                      'SMS Direct Dispatch',
                      style: TextStyle(color: _textPrimary, fontWeight: FontWeight.w700),
                    ),
                    subtitle: const Text(
                      'Sends SMS with emergency coordinates if internet drops',
                      style: TextStyle(color: _textMuted, fontSize: 12),
                    ),
                    onChanged: (val) {
                      setSheetState(() {
                        _handleSmsToggle(s, val);
                      });
                    },
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    value: s.emergencyWhatsApp,
                    activeColor: _tealAccent,
                    title: const Text(
                      'WhatsApp Cloud Alert',
                      style: TextStyle(color: _textPrimary, fontWeight: FontWeight.w700),
                    ),
                    subtitle: const Text(
                      'Dispatches verified WhatsApp SOS with live tracking link',
                      style: TextStyle(color: _textMuted, fontSize: 12),
                    ),
                    onChanged: (val) {
                      setSheetState(() {
                        s.setEmergencyWhatsApp(val);
                      });
                    },
                  ),
                  const SizedBox(height: 24),
                  SizedBox(
                    height: 52,
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _tealAccent,
                        foregroundColor: Colors.black,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      onPressed: () async {
                        final navigator = Navigator.of(ctx);
                        final messenger = ScaffoldMessenger.of(context);
                        try {
                          await auth.updateProfile(
                            phone: auth.phone ?? '',
                            vehicleType: auth.vehicleType ?? 'Motorcycle',
                            vehicleNo: auth.vehicleNo ?? '',
                            emergencyContact: phoneCtrl.text.trim(),
                            emergencyContactName: nameCtrl.text.trim(),
                          );
                          navigator.pop();
                          if (mounted) {
                            messenger.showSnackBar(
                              const SnackBar(
                                content: Text('Emergency contact saved.'),
                                behavior: SnackBarBehavior.floating,
                              ),
                            );
                          }
                        } catch (e) {
                          if (mounted) {
                            messenger.showSnackBar(
                              SnackBar(
                                content: Text('Failed to update emergency contact: $e'),
                                behavior: SnackBarBehavior.floating,
                                backgroundColor: Colors.redAccent,
                              ),
                            );
                          }
                        }
                      },
                      child: const Text(
                        'Save Contact',
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watch<SettingsService?>();
    final auth = context.watch<AuthService?>();
    final helmetVoice = context.watch<HelmetVoiceService?>();
    final bleRemote = context.watch<BleRemoteService?>();

    if (s == null) {
      return const Scaffold(
        backgroundColor: _bg,
        body: Center(child: CircularProgressIndicator(color: _tealAccent)),
      );
    }

    // Airbag bridge state
    final airbag = SmartAirbagBridgeService.instance;
    final isAirbagConnected = airbag.connectionState == AirbagConnectionState.connected;

    // Biometric vitals state
    final bioBridge = BiometricSafetyBridge();
    final isBioConnected = bioBridge.snapshot.isConnected || bioBridge.snapshot.isWatchOnWrist;

    // BLE remote state
    final isRemotePaired = bleRemote?.status == BleRemoteStatus.paired;

    // Emergency contact status
    final hasEmergencyContact = (auth?.emergencyContact ?? '').trim().isNotEmpty;

    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: _bg,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        title: const Text(
          'Rider Settings',
          style: TextStyle(
            color: _textPrimary,
            fontSize: 20,
            fontWeight: FontWeight.w800,
          ),
        ),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded, color: _textPrimary),
          onPressed: () => Navigator.maybePop(context),
        ),
        actions: [
          Container(
            margin: const EdgeInsets.only(right: 16),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: const Color(0xFF0F2B33),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: const Color(0xFF194C59)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 7,
                  height: 7,
                  decoration: const BoxDecoration(
                    color: _tealAccent,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 6),
                const Text(
                  'GLOVE READY',
                  style: TextStyle(
                    color: _tealAccent,
                    fontSize: 10,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.6,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          children: [
            // Subtitle banner
            const Padding(
              padding: EdgeInsets.only(left: 4, bottom: 16),
              child: Text(
                'Distraction-free ergonomics. Every essential control reachable in one tap.',
                style: TextStyle(
                  color: _textMuted,
                  fontSize: 13,
                  height: 1.4,
                ),
              ),
            ),

            // SECTION 1: 🛡️ Safety Shield
            _CardSection(
              headerEmoji: '🛡️',
              headerTitle: 'Safety Shield',
              children: [
                _GloveSettingSwitchRow(
                  icon: Icons.car_crash_rounded,
                  title: 'Automatic Crash Detection',
                  description: 'Instant 15s alarm before dispatch',
                  value: s.crashDetection,
                  statusText: s.crashDetection ? 'Ready' : 'Off',
                  statusKind: s.crashDetection ? _BadgeKind.ready : _BadgeKind.off,
                  onChanged: (v) => s.setCrashDetection(v),
                ),
                _GloveSettingSwitchRow(
                  icon: Icons.shield_rounded,
                  title: 'Smart Airbag Vest Bridge',
                  description: 'Auto-detects In&motion, Tech-Air, Helite',
                  value: s.airbagVestBridge,
                  statusText: !s.airbagVestBridge
                      ? 'Off'
                      : (isAirbagConnected ? 'Connected' : 'Ready'),
                  statusKind: !s.airbagVestBridge
                      ? _BadgeKind.off
                      : (isAirbagConnected ? _BadgeKind.connected : _BadgeKind.ready),
                  onChanged: (v) => s.setAirbagVestBridge(v),
                ),
                _GloveSettingSwitchRow(
                  icon: Icons.watch_rounded,
                  title: 'Smartwatch Vitals',
                  description: 'Monitors pulse & escalates trauma alerts',
                  value: s.smartwatchVitals,
                  statusText: !s.smartwatchVitals
                      ? 'Off'
                      : (isBioConnected ? 'Connected' : 'Ready'),
                  statusKind: !s.smartwatchVitals
                      ? _BadgeKind.off
                      : (isBioConnected ? _BadgeKind.connected : _BadgeKind.ready),
                  onChanged: (v) => s.setSmartwatchVitals(v),
                ),
                _GloveSettingSwitchRow(
                  icon: Icons.campaign_rounded,
                  title: 'Emergency Siren Alert',
                  description: 'Ducks intercom when ambulances approach',
                  value: s.emergencySirenAlert,
                  statusText: s.emergencySirenAlert ? 'Ready' : 'Off',
                  statusKind: s.emergencySirenAlert ? _BadgeKind.ready : _BadgeKind.off,
                  onChanged: (v) => s.setEmergencySirenAlert(v),
                  showDivider: false,
                ),
              ],
            ),

            const SizedBox(height: 18),

            // SECTION 2: 🗺️ Navigation & Tunnels
            _CardSection(
              headerEmoji: '🗺️',
              headerTitle: 'Navigation & Tunnels',
              children: [
                _GloveSettingSwitchRow(
                  icon: Icons.alt_route_rounded,
                  title: 'Tunnel Dead Reckoning',
                  description: 'Keeps moving through GPS-dead mountain tunnels',
                  value: s.tunnelDeadReckoning,
                  statusText: s.tunnelDeadReckoning ? 'Ready' : 'Off',
                  statusKind: s.tunnelDeadReckoning ? _BadgeKind.ready : _BadgeKind.off,
                  onChanged: (v) => s.setTunnelDeadReckoning(v),
                ),
                _GloveSettingSwitchRow(
                  icon: Icons.screen_lock_portrait_rounded,
                  title: 'Lock-Screen Radar',
                  description: 'Glanceable group distance on lock screen',
                  value: s.rideOnLockScreen,
                  statusText: s.rideOnLockScreen ? 'Ready' : 'Off',
                  statusKind: s.rideOnLockScreen ? _BadgeKind.ready : _BadgeKind.off,
                  onChanged: (v) => s.setRideOnLockScreen(v),
                ),
                _GloveSettingSwitchRow(
                  icon: Icons.warning_amber_rounded,
                  title: 'Road Hazard Alerts',
                  description: 'Warns of potholes & road debris 300m ahead',
                  value: s.hazardAlerts,
                  statusText: s.hazardAlerts ? 'Ready' : 'Off',
                  statusKind: s.hazardAlerts ? _BadgeKind.ready : _BadgeKind.off,
                  onChanged: (v) => s.setHazardAlerts(v),
                  showDivider: false,
                ),
              ],
            ),

            const SizedBox(height: 18),

            // SECTION 3: 🎙️ Audio & Controls
            _CardSection(
              headerEmoji: '🎙️',
              headerTitle: 'Audio & Controls',
              children: [
                _GloveSettingSwitchRow(
                  icon: Icons.sports_motorsports_rounded,
                  title: 'Handlebar Remote',
                  description: 'PTT voice & SOS button on handlebar',
                  value: s.hardwarePtt,
                  statusText: !s.hardwarePtt
                      ? 'Off'
                      : (isRemotePaired ? 'Connected' : 'Ready'),
                  statusKind: !s.hardwarePtt
                      ? _BadgeKind.off
                      : (isRemotePaired ? _BadgeKind.connected : _BadgeKind.ready),
                  onChanged: (v) => s.setHardwarePtt(v),
                ),
                _GloveSettingSwitchRow(
                  icon: Icons.mic_rounded,
                  title: 'Helmet Voice Hotwords',
                  description: 'Hands-free "CoRoute I\'m OK" & "CoRoute Emergency"',
                  value: s.helmetVoiceHotwords,
                  statusText: s.helmetVoiceHotwords ? 'Ready' : 'Off',
                  statusKind: s.helmetVoiceHotwords ? _BadgeKind.ready : _BadgeKind.off,
                  onChanged: (v) {
                    s.setHelmetVoiceHotwords(v);
                    helmetVoice?.setEnabled(v);
                  },
                ),
                _GloveSettingSwitchRow(
                  icon: Icons.volume_down_rounded,
                  title: 'Intercom Audio Ducking',
                  description: 'Ducks chatter when Road Captain or sirens speak',
                  value: s.intercomAudioDucking,
                  statusText: s.intercomAudioDucking ? 'Ready' : 'Off',
                  statusKind: s.intercomAudioDucking ? _BadgeKind.ready : _BadgeKind.off,
                  onChanged: (v) => s.setIntercomAudioDucking(v),
                  showDivider: false,
                ),
              ],
            ),

            const SizedBox(height: 18),

            // SECTION 4: 👤 Rider Identity & Contacts
            _CardSection(
              headerEmoji: '👤',
              headerTitle: 'Rider Identity & Contacts',
              children: [
                _GloveActionRow(
                  icon: Icons.badge_rounded,
                  title: 'Callsign & Blood Group',
                  description: (auth?.currentUserName?.isNotEmpty == true || auth?.bloodGroup.isNotEmpty == true)
                      ? '${auth?.currentUserName ?? "Rider"} · Blood: ${auth?.bloodGroup.isNotEmpty == true ? auth!.bloodGroup : "Not set"}'
                      : 'Set your callsign and medical blood group',
                  statusText: auth?.bloodGroup.isNotEmpty == true ? auth!.bloodGroup : 'Ready',
                  statusKind: _BadgeKind.ready,
                  onTap: () => _openRiderIdentitySheet(context, auth),
                ),
                _GloveActionRow(
                  icon: Icons.contact_emergency_rounded,
                  title: 'Emergency Contacts',
                  description: hasEmergencyContact
                      ? '${auth?.emergencyContactName ?? "Contact"}: ${auth?.emergencyContact}'
                      : 'SMS & WhatsApp alerts with live GPS location',
                  statusText: hasEmergencyContact ? 'Ready' : 'Off',
                  statusKind: hasEmergencyContact ? _BadgeKind.ready : _BadgeKind.off,
                  onTap: () => _openEmergencyContactsSheet(context, auth, s),
                  showDivider: false,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Reusable Minimal Ergonomic Components
// ---------------------------------------------------------------------------

enum _BadgeKind { connected, ready, off }

class _CardSection extends StatelessWidget {
  final String headerEmoji;
  final String headerTitle;
  final List<Widget> children;

  const _CardSection({
    required this.headerEmoji,
    required this.headerTitle,
    required this.children,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 8),
          child: Row(
            children: [
              Text(headerEmoji, style: const TextStyle(fontSize: 14)),
              const SizedBox(width: 8),
              Text(
                headerTitle.toUpperCase(),
                style: const TextStyle(
                  color: Color(0xFFF2F6F8),
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.8,
                ),
              ),
            ],
          ),
        ),
        Container(
          decoration: BoxDecoration(
            color: const Color(0xFF14171A),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: const Color(0xFF22282F), width: 1.2),
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: children,
          ),
        ),
      ],
    );
  }
}

class _StatusBadge extends StatelessWidget {
  final String text;
  final _BadgeKind kind;

  const _StatusBadge({required this.text, required this.kind});

  @override
  Widget build(BuildContext context) {
    Color bg;
    Color border;
    Color textColor;
    bool hasDot;

    switch (kind) {
      case _BadgeKind.connected:
        bg = const Color(0xFF0D2E24);
        border = const Color(0xFF1B6B54);
        textColor = const Color(0xFF34D399);
        hasDot = true;
        break;
      case _BadgeKind.ready:
        bg = const Color(0xFF0F2B33);
        border = const Color(0xFF194C59);
        textColor = const Color(0xFF5CCAD3);
        hasDot = true;
        break;
      case _BadgeKind.off:
        bg = const Color(0xFF1E2328);
        border = const Color(0xFF2D353C);
        textColor = const Color(0xFF7A8B99);
        hasDot = false;
        break;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: border, width: 1),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (hasDot) ...[
            Container(
              width: 5,
              height: 5,
              decoration: BoxDecoration(color: textColor, shape: BoxShape.circle),
            ),
            const SizedBox(width: 5),
          ],
          Text(
            text.toUpperCase(),
            style: TextStyle(
              color: textColor,
              fontSize: 10,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.5,
            ),
          ),
        ],
      ),
    );
  }
}

class _GloveSettingSwitchRow extends StatelessWidget {
  final IconData icon;
  final String title;
  final String description;
  final bool value;
  final String statusText;
  final _BadgeKind statusKind;
  final ValueChanged<bool> onChanged;
  final bool showDivider;

  const _GloveSettingSwitchRow({
    required this.icon,
    required this.title,
    required this.description,
    required this.value,
    required this.statusText,
    required this.statusKind,
    required this.onChanged,
    this.showDivider = true,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        InkWell(
          onTap: () => onChanged(!value),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 56),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                children: [
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: const Color(0xFF1B2228),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(icon, color: const Color(0xFF5CCAD3), size: 20),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Color(0xFFF2F6F8),
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          description,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Color(0xFF9BAAB5),
                            fontSize: 12.5,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 10),
                  _StatusBadge(text: statusText, kind: statusKind),
                  const SizedBox(width: 10),
                  Switch(
                    value: value,
                    activeColor: const Color(0xFF5CCAD3),
                    onChanged: onChanged,
                    materialTapTargetSize: MaterialTapTargetSize.padded,
                  ),
                ],
              ),
            ),
          ),
        ),
        if (showDivider)
          const Divider(
            height: 1,
            thickness: 1,
            color: Color(0xFF1D242B),
            indent: 66,
          ),
      ],
    );
  }
}

class _GloveActionRow extends StatelessWidget {
  final IconData icon;
  final String title;
  final String description;
  final String statusText;
  final _BadgeKind statusKind;
  final VoidCallback onTap;
  final bool showDivider;

  const _GloveActionRow({
    required this.icon,
    required this.title,
    required this.description,
    required this.statusText,
    required this.statusKind,
    required this.onTap,
    this.showDivider = true,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        InkWell(
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 56),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                children: [
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: const Color(0xFF1B2228),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(icon, color: const Color(0xFF5CCAD3), size: 20),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Color(0xFFF2F6F8),
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          description,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Color(0xFF9BAAB5),
                            fontSize: 12.5,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 10),
                  _StatusBadge(text: statusText, kind: statusKind),
                  const SizedBox(width: 8),
                  const Icon(
                    Icons.chevron_right_rounded,
                    color: Color(0xFF7A8B99),
                    size: 22,
                  ),
                ],
              ),
            ),
          ),
        ),
        if (showDivider)
          const Divider(
            height: 1,
            thickness: 1,
            color: Color(0xFF1D242B),
            indent: 66,
          ),
      ],
    );
  }
}
