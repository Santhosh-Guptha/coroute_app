import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/glass_card.dart';
import '../../data/services/auth_service.dart';

/// Rider profile and emergency ICE contact settings.
/// Riders can maintain their phone number, vehicle type & registration,
/// and primary emergency contact for SOS distress triggers.
class EditProfileScreen extends StatefulWidget {
  const EditProfileScreen({super.key});

  @override
  State<EditProfileScreen> createState() => _EditProfileScreenState();
}

class _EditProfileScreenState extends State<EditProfileScreen> {
  final _phoneController = TextEditingController();
  final _vehicleNoController = TextEditingController();
  final _iceNameController = TextEditingController();
  final _icePhoneController = TextEditingController();

  static const List<String> _vehicleTypes = [
    'Motorcycle (Adv)',
    'Motorcycle (Cruiser)',
    'Motorcycle (Sport)',
    'Motorcycle (Commuter)',
    'Scooter / Maxi',
    'Pillion Rider',
    'Support / Chase Car',
    'Other',
  ];

  late String _selectedVehicle;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final auth = context.read<AuthService>();
    _phoneController.text = auth.phone ?? '';
    _iceNameController.text = auth.emergencyContactName ?? '';
    _icePhoneController.text = auth.emergencyContact ?? '';

    final currentVehicle = auth.vehicleType ?? '';
    if (auth.isPillion || currentVehicle == 'Pillion Rider' || auth.vehicleNo == 'PILLION') {
      _selectedVehicle = 'Pillion Rider';
      _vehicleNoController.text = 'PILLION';
    } else if (_vehicleTypes.contains(currentVehicle)) {
      _selectedVehicle = currentVehicle;
      _vehicleNoController.text = auth.vehicleNo ?? '';
    } else if (currentVehicle.isNotEmpty) {
      _selectedVehicle = 'Other';
      _vehicleNoController.text = auth.vehicleNo ?? '';
    } else {
      _selectedVehicle = _vehicleTypes.first;
      _vehicleNoController.text = auth.vehicleNo ?? '';
    }
  }

  @override
  void dispose() {
    _phoneController.dispose();
    _vehicleNoController.dispose();
    _iceNameController.dispose();
    _icePhoneController.dispose();
    super.dispose();
  }

  InputDecoration _inputDec({required String label, String? hint, IconData? prefixIcon}) {
    return InputDecoration(
      labelText: label,
      hintText: hint,
      labelStyle: TextStyle(color: AppTheme.textMuted, fontSize: 13),
      hintStyle: TextStyle(color: AppTheme.textMuted.withOpacity(0.6), fontSize: 12),
      prefixIcon: prefixIcon != null ? Icon(prefixIcon, color: AppTheme.neonCyan, size: 18) : null,
      filled: true,
      fillColor: AppTheme.elevatedCard,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: AppTheme.glassBorder)),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: AppTheme.glassBorder)),
      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: AppTheme.neonCyan)),
    );
  }

  Future<void> _save() async {
    final phone = _phoneController.text.trim();
    final isPillion = _selectedVehicle == 'Pillion Rider';
    final vehicleNo = _vehicleNoController.text.trim().toUpperCase();
    final iceName = _iceNameController.text.trim();
    final icePhone = _icePhoneController.text.trim();

    if (phone.length < 7) {
      setState(() => _error = 'Please provide a valid mobile phone number.');
      return;
    }
    if (!isPillion && vehicleNo.length < 3) {
      setState(() => _error = 'Bike / vehicle registration number is mandatory for riders (or select Pillion Rider).');
      return;
    }
    if (iceName.length < 2) {
      setState(() => _error = 'Emergency (ICE) contact name is mandatory for ride safety.');
      return;
    }
    if (icePhone.length < 7) {
      setState(() => _error = 'Emergency (ICE) contact phone number is mandatory for SOS alerts.');
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });

    final success = await context.read<AuthService>().updateProfile(
      phone: phone,
      vehicleType: _selectedVehicle,
      vehicleNo: isPillion ? 'PILLION' : vehicleNo,
      emergencyContact: icePhone,
      emergencyContactName: iceName,
    );

    if (!mounted) return;
    setState(() => _busy = false);

    if (success) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Row(
            children: [
              Icon(Icons.check_circle_rounded, color: Colors.white, size: 18),
              SizedBox(width: 8),
              Text('Profile & emergency contact saved successfully.'),
            ],
          ),
          backgroundColor: AppTheme.emeraldSafe,
        ),
      );
      Navigator.pop(context, true);
    } else {
      setState(() {
        _error = 'Failed to update profile. Please verify your connection.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthService>();

    return Scaffold(
      backgroundColor: AppTheme.obsidianVoid,
      appBar: AppBar(
        title: const Text('Rider Profile & ICE'),
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 540),
          child: ListView(
            cacheExtent: 1500,
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
            children: [
              // User identity badge
              GlassCard(
                child: Row(
                  children: [
                    CircleAvatar(
                      radius: 24,
                      backgroundColor: AppTheme.elevatedCard,
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
                            style: TextStyle(color: AppTheme.textMuted, fontSize: 12),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 20),

              if (_error != null) ...[
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AppTheme.laserRed.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: AppTheme.laserRed.withOpacity(0.4)),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.error_outline_rounded, color: AppTheme.laserRed, size: 20),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(_error!, style: TextStyle(color: AppTheme.laserRed, fontSize: 13)),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
              ],

              // Contact section
              _sectionHeader('Contact Information'),
              TextField(
                controller: _phoneController,
                keyboardType: TextInputType.phone,
                style: TextStyle(color: AppTheme.textPrimary, fontSize: 14),
                decoration: _inputDec(
                  label: 'Rider Mobile Number',
                  hint: '+91 98765 43210',
                  prefixIcon: Icons.phone_android_rounded,
                ),
              ),

              const SizedBox(height: 20),

              // Vehicle section
              _sectionHeader('Vehicle Details'),
              Row(
                children: [
                  Expanded(
                    flex: 6,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('VEHICLE TYPE', style: TextStyle(color: AppTheme.textMuted, fontSize: 11, fontWeight: FontWeight.bold)),
                        const SizedBox(height: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                          decoration: BoxDecoration(
                            color: AppTheme.elevatedCard,
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: AppTheme.glassBorder),
                          ),
                          child: DropdownButtonHideUnderline(
                            child: DropdownButton<String>(
                              value: _selectedVehicle,
                              dropdownColor: AppTheme.slateCard,
                              isExpanded: true,
                              style: TextStyle(color: AppTheme.textPrimary, fontSize: 13),
                              items: _vehicleTypes.map((v) => DropdownMenuItem(value: v, child: Text(v, overflow: TextOverflow.ellipsis))).toList(),
                              onChanged: (val) {
                                if (val != null) {
                                  setState(() {
                                    _selectedVehicle = val;
                                    if (val == 'Pillion Rider') {
                                      _vehicleNoController.text = 'PILLION';
                                    } else if (_vehicleNoController.text == 'PILLION') {
                                      _vehicleNoController.text = '';
                                    }
                                  });
                                }
                              },
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 5,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('REGISTRATION NO', style: TextStyle(color: AppTheme.textMuted, fontSize: 11, fontWeight: FontWeight.bold)),
                        const SizedBox(height: 6),
                        TextField(
                          controller: _vehicleNoController,
                          enabled: _selectedVehicle != 'Pillion Rider',
                          textCapitalization: TextCapitalization.characters,
                          style: TextStyle(
                            color: _selectedVehicle == 'Pillion Rider' ? AppTheme.textMuted : AppTheme.textPrimary,
                            fontSize: 13,
                          ),
                          decoration: _inputDec(
                            label: _selectedVehicle == 'Pillion Rider' ? 'Not Required' : 'Plate No *',
                            hint: _selectedVehicle == 'Pillion Rider' ? 'PILLION' : 'KA 01 AB 1234',
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 24),

              // ICE Section
              _sectionHeader('In Case of Emergency (ICE) Contact'),
              Container(
                padding: const EdgeInsets.all(12),
                margin: const EdgeInsets.only(bottom: 12),
                decoration: BoxDecoration(
                  color: AppTheme.hyperAmber.withOpacity(0.08),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: AppTheme.hyperAmber.withOpacity(0.25)),
                ),
                child: Row(
                  children: [
                    Icon(Icons.shield_outlined, color: AppTheme.hyperAmber, size: 20),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'During an SOS distress trigger, this contact can be called directly and will receive an SMS with your exact GPS map coordinates.',
                        style: TextStyle(color: AppTheme.textSecondary, fontSize: 11, height: 1.3),
                      ),
                    ),
                  ],
                ),
              ),

              TextField(
                controller: _iceNameController,
                textCapitalization: TextCapitalization.words,
                style: TextStyle(color: AppTheme.textPrimary, fontSize: 14),
                decoration: _inputDec(
                  label: 'ICE Contact Name / Relationship',
                  hint: 'e.g. Spouse, Brother, Mother',
                  prefixIcon: Icons.person_pin_rounded,
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _icePhoneController,
                keyboardType: TextInputType.phone,
                style: TextStyle(color: AppTheme.textPrimary, fontSize: 14),
                decoration: _inputDec(
                  label: 'ICE Contact Phone Number',
                  hint: '+91 98765 43210',
                  prefixIcon: Icons.phone_in_talk_rounded,
                ),
              ),

              const SizedBox(height: 28),

              // Save button
              SizedBox(
                width: double.infinity,
                height: 48,
                child: ElevatedButton(
                  onPressed: _busy ? null : _save,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppTheme.neonCyan,
                    foregroundColor: Colors.black,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                  child: _busy
                      ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black))
                      : const Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.save_rounded, size: 18),
                            SizedBox(width: 8),
                            Text('SAVE PROFILE & CONTACTS', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, letterSpacing: 0.5)),
                          ],
                        ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _sectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 8),
      child: Text(
        title.toUpperCase(),
        style: TextStyle(color: AppTheme.textMuted, fontSize: 11, fontWeight: FontWeight.bold, letterSpacing: 1.1),
      ),
    );
  }
}
