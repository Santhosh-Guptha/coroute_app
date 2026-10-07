import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/glass_card.dart';
import '../../data/services/auth_service.dart';
import 'access_gate_screen.dart';

/// Mandatory profile completion screen.
/// Enforces that all users (newly signed in with Google, or existing users with incomplete records)
/// provide mandatory contact numbers, vehicle registration (or pillion status), and emergency ICE contacts.
class CompleteProfileScreen extends StatefulWidget {
  final bool forced;
  final bool isGoogleUser;

  const CompleteProfileScreen({
    super.key,
    this.forced = false,
    this.isGoogleUser = false,
  });

  @override
  State<CompleteProfileScreen> createState() => _CompleteProfileScreenState();
}

class _CompleteProfileScreenState extends State<CompleteProfileScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _phoneController = TextEditingController();
  final _vehicleNoController = TextEditingController();
  final _iceNameController = TextEditingController();
  final _icePhoneController = TextEditingController();

  bool _isPillion = false;
  String _selectedVehicle = 'Motorcycle (Adv)';
  bool _isLoading = false;
  String? _errorMessage;

  static const List<String> _vehicleTypes = [
    'Motorcycle (Adv)',
    'Motorcycle (Cruiser)',
    'Motorcycle (Sport)',
    'Motorcycle (Commuter)',
    'Scooter / Maxi',
    'Support Car / SUV',
    'Other',
  ];

  @override
  void initState() {
    super.initState();
    final auth = context.read<AuthService>();
    _nameController.text = auth.currentUserName ?? '';
    _phoneController.text = auth.phone ?? '';
    _isPillion = auth.isPillion;

    if (_isPillion) {
      _vehicleNoController.text = '';
    } else {
      _vehicleNoController.text = (auth.vehicleNo == 'PILLION' ? '' : auth.vehicleNo) ?? '';
    }

    _iceNameController.text = auth.emergencyContactName ?? '';
    _icePhoneController.text = auth.emergencyContact ?? '';

    final currentVehicle = auth.vehicleType ?? '';
    if (_vehicleTypes.contains(currentVehicle)) {
      _selectedVehicle = currentVehicle;
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _phoneController.dispose();
    _vehicleNoController.dispose();
    _iceNameController.dispose();
    _icePhoneController.dispose();
    super.dispose();
  }

  Future<void> _handleSave() async {
    final name = _nameController.text.trim();
    final phone = _phoneController.text.trim();
    final vehicleNo = _vehicleNoController.text.trim().toUpperCase();
    final iceName = _iceNameController.text.trim();
    final icePhone = _icePhoneController.text.trim();

    if (name.length < 2) {
      setState(() => _errorMessage = 'Please enter your full name or callsign.');
      return;
    }
    if (phone.length < 7) {
      setState(() => _errorMessage = 'Please provide a valid mobile contact number.');
      return;
    }
    if (!_isPillion && vehicleNo.length < 3) {
      setState(() => _errorMessage = 'Bike / vehicle registration number is mandatory for riders (or select Pillion Rider).');
      return;
    }
    if (iceName.length < 2) {
      setState(() => _errorMessage = 'Emergency (ICE) contact name is mandatory for ride safety.');
      return;
    }
    if (icePhone.length < 7) {
      setState(() => _errorMessage = 'Emergency (ICE) contact phone number is mandatory for SOS alerts.');
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    final auth = context.read<AuthService>();
    final success = await auth.updateProfile(
      name: name,
      phone: phone,
      vehicleType: _isPillion ? 'Pillion Rider' : _selectedVehicle,
      vehicleNo: _isPillion ? 'PILLION' : vehicleNo,
      emergencyContact: icePhone,
      emergencyContactName: iceName,
    );

    if (!mounted) return;
    setState(() => _isLoading = false);

    if (success) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Row(
            children: [
              Icon(Icons.verified_user_rounded, color: Colors.white, size: 20),
              SizedBox(width: 10),
              Expanded(child: Text('Profile details updated! Ride safety features unlocked.')),
            ],
          ),
          backgroundColor: AppTheme.emeraldSafe,
        ),
      );
      Navigator.pop(context, true);
    } else {
      setState(() {
        _errorMessage = 'Could not update profile. Please verify your connection.';
      });
    }
  }

  Future<void> _handleSignOut() async {
    await context.read<AuthService>().logout();
    if (!mounted) return;
    Navigator.pushAndRemoveUntil(
      context,
      MaterialPageRoute(builder: (_) => const AccessGateScreen()),
      (route) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !widget.forced,
      child: Scaffold(
        backgroundColor: AppTheme.obsidianVoid,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          title: const Text('Mandatory Safety Details'),
          automaticallyImplyLeading: !widget.forced,
          actions: [
            if (widget.forced)
              TextButton.icon(
                onPressed: _handleSignOut,
                icon: Icon(Icons.logout, color: AppTheme.laserRed, size: 16),
                label: Text('Sign Out', style: TextStyle(color: AppTheme.laserRed, fontSize: 13)),
              ),
          ],
        ),
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 580),
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Header Card
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: AppTheme.hyperAmber.withOpacity(0.12),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: AppTheme.hyperAmber.withOpacity(0.5)),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(Icons.shield_rounded, color: AppTheme.hyperAmber, size: 28),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  widget.isGoogleUser
                                      ? 'Google Sign-In: Complete Profile'
                                      : 'Mandatory Safety Registration',
                                  style: TextStyle(
                                    color: AppTheme.hyperAmber,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 15,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  'CoRoute requires all riders and pillion passengers to have verified contact numbers, vehicle details, and emergency (ICE) contacts before creating or joining convoys.',
                                  style: TextStyle(color: AppTheme.textSecondary, fontSize: 12, height: 1.4),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),

                    if (_errorMessage != null) ...[
                      const SizedBox(height: 14),
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: AppTheme.laserRed.withOpacity(0.15),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: AppTheme.laserRed),
                        ),
                        child: Row(
                          children: [
                            Icon(Icons.error_outline, color: AppTheme.laserRed, size: 20),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                _errorMessage!,
                                style: TextStyle(color: AppTheme.laserRed, fontSize: 12, fontWeight: FontWeight.w600),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],

                    const SizedBox(height: 20),

                    // Section 1: Rider Identity & Contact
                    Text('1. RIDER IDENTITY & CONTACT', style: TextStyle(color: AppTheme.neonCyan, fontSize: 11, fontWeight: FontWeight.bold, letterSpacing: 0.8)),
                    const SizedBox(height: 8),
                    GlassCard(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('FULL NAME / CALLSIGN *', style: TextStyle(color: AppTheme.textSecondary, fontSize: 10, fontWeight: FontWeight.bold)),
                          const SizedBox(height: 6),
                          TextField(
                            controller: _nameController,
                            style: TextStyle(color: AppTheme.textPrimary, fontSize: 13),
                            decoration: InputDecoration(
                              prefixIcon: Icon(Icons.person_outline, color: AppTheme.neonCyan, size: 18),
                              hintText: 'e.g. Santhosh Rider',
                              filled: true,
                              fillColor: AppTheme.elevatedCard,
                              border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                            ),
                          ),
                          const SizedBox(height: 14),
                          Text('MOBILE PHONE NUMBER *', style: TextStyle(color: AppTheme.textSecondary, fontSize: 10, fontWeight: FontWeight.bold)),
                          const SizedBox(height: 6),
                          TextField(
                            controller: _phoneController,
                            keyboardType: TextInputType.phone,
                            style: TextStyle(color: AppTheme.textPrimary, fontSize: 13),
                            decoration: InputDecoration(
                              prefixIcon: Icon(Icons.phone_android, color: AppTheme.neonCyan, size: 18),
                              hintText: 'e.g. +91 98765 43210',
                              filled: true,
                              fillColor: AppTheme.elevatedCard,
                              border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                            ),
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 20),

                    // Section 2: Rider Role & Vehicle Details
                    Text('2. RIDER ROLE & VEHICLE DETAILS', style: TextStyle(color: AppTheme.neonCyan, fontSize: 11, fontWeight: FontWeight.bold, letterSpacing: 0.8)),
                    const SizedBox(height: 8),
                    GlassCard(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('ARE YOU RIDING OR A PILLION PASSENGER? *', style: TextStyle(color: AppTheme.textSecondary, fontSize: 10, fontWeight: FontWeight.bold)),
                          const SizedBox(height: 10),
                          Row(
                            children: [
                              Expanded(
                                child: ChoiceChip(
                                  label: const Row(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      Icon(Icons.two_wheeler, size: 16),
                                      SizedBox(width: 6),
                                      Text('Bike Rider / Pilot'),
                                    ],
                                  ),
                                  selected: !_isPillion,
                                  onSelected: (val) {
                                    if (val) setState(() => _isPillion = false);
                                  },
                                  selectedColor: AppTheme.neonCyan,
                                  labelStyle: TextStyle(
                                    color: !_isPillion ? Colors.black : AppTheme.textPrimary,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 12,
                                  ),
                                  backgroundColor: AppTheme.elevatedCard,
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: ChoiceChip(
                                  label: const Row(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      Icon(Icons.airline_seat_recline_normal, size: 16),
                                      SizedBox(width: 6),
                                      Text('Pillion Rider'),
                                    ],
                                  ),
                                  selected: _isPillion,
                                  onSelected: (val) {
                                    if (val) setState(() => _isPillion = true);
                                  },
                                  selectedColor: AppTheme.hyperAmber,
                                  labelStyle: TextStyle(
                                    color: _isPillion ? Colors.black : AppTheme.textPrimary,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 12,
                                  ),
                                  backgroundColor: AppTheme.elevatedCard,
                                ),
                              ),
                            ],
                          ),

                          const SizedBox(height: 16),

                          if (!_isPillion) ...[
                            Text('VEHICLE TYPE', style: TextStyle(color: AppTheme.textSecondary, fontSize: 10, fontWeight: FontWeight.bold)),
                            const SizedBox(height: 6),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 10),
                              decoration: BoxDecoration(
                                color: AppTheme.elevatedCard,
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(color: AppTheme.glassBorder),
                              ),
                              child: DropdownButtonHideUnderline(
                                child: DropdownButton<String>(
                                  value: _vehicleTypes.contains(_selectedVehicle) ? _selectedVehicle : _vehicleTypes.first,
                                  dropdownColor: AppTheme.slateCard,
                                  isExpanded: true,
                                  style: TextStyle(color: AppTheme.textPrimary, fontSize: 13),
                                  items: _vehicleTypes.map((v) => DropdownMenuItem(value: v, child: Text(v))).toList(),
                                  onChanged: (val) {
                                    if (val != null) setState(() => _selectedVehicle = val);
                                  },
                                ),
                              ),
                            ),
                            const SizedBox(height: 14),
                            Text('BIKE / VEHICLE REGISTRATION NUMBER *', style: TextStyle(color: AppTheme.textSecondary, fontSize: 10, fontWeight: FontWeight.bold)),
                            const SizedBox(height: 6),
                            TextField(
                              controller: _vehicleNoController,
                              textCapitalization: TextCapitalization.characters,
                              style: TextStyle(color: AppTheme.textPrimary, fontSize: 13, letterSpacing: 1.2),
                              decoration: InputDecoration(
                                prefixIcon: Icon(Icons.numbers, color: AppTheme.neonCyan, size: 18),
                                hintText: 'e.g. KA 01 AB 1234',
                                filled: true,
                                fillColor: AppTheme.elevatedCard,
                                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                              ),
                            ),
                          ] else ...[
                            Container(
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: AppTheme.hyperAmber.withOpacity(0.08),
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(color: AppTheme.hyperAmber.withOpacity(0.3)),
                              ),
                              child: Row(
                                children: [
                                  Icon(Icons.check_circle_outline, color: AppTheme.hyperAmber, size: 20),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Text(
                                      'Registered as Pillion Rider. You will join convoys paired with your pilot and do not require a personal bike registration.',
                                      style: TextStyle(color: AppTheme.textSecondary, fontSize: 11),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),

                    const SizedBox(height: 20),

                    // Section 3: Emergency ICE Contacts
                    Text('3. EMERGENCY (ICE) CONTACTS *', style: TextStyle(color: AppTheme.laserRed, fontSize: 11, fontWeight: FontWeight.bold, letterSpacing: 0.8)),
                    const SizedBox(height: 8),
                    GlassCard(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('EMERGENCY CONTACT NAME *', style: TextStyle(color: AppTheme.textSecondary, fontSize: 10, fontWeight: FontWeight.bold)),
                          const SizedBox(height: 6),
                          TextField(
                            controller: _iceNameController,
                            style: TextStyle(color: AppTheme.textPrimary, fontSize: 13),
                            decoration: InputDecoration(
                              prefixIcon: Icon(Icons.contact_emergency, color: AppTheme.laserRed, size: 18),
                              hintText: 'e.g. Spouse / Brother / Parent',
                              filled: true,
                              fillColor: AppTheme.elevatedCard,
                              border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                            ),
                          ),
                          const SizedBox(height: 14),
                          Text('EMERGENCY CONTACT PHONE NUMBER *', style: TextStyle(color: AppTheme.textSecondary, fontSize: 10, fontWeight: FontWeight.bold)),
                          const SizedBox(height: 6),
                          TextField(
                            controller: _icePhoneController,
                            keyboardType: TextInputType.phone,
                            style: TextStyle(color: AppTheme.textPrimary, fontSize: 13),
                            decoration: InputDecoration(
                              prefixIcon: Icon(Icons.phone_in_talk, color: AppTheme.laserRed, size: 18),
                              hintText: 'e.g. +91 91234 56780',
                              filled: true,
                              fillColor: AppTheme.elevatedCard,
                              border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                            ),
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 24),

                    // Submit Button
                    SizedBox(
                      width: double.infinity,
                      height: 50,
                      child: ElevatedButton(
                        onPressed: _isLoading ? null : _handleSave,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppTheme.neonCyan,
                          foregroundColor: Colors.black,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          elevation: 4,
                        ),
                        child: _isLoading
                            ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black))
                            : const Text('SAVE & UNLOCK CONVOY RIDES', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14, letterSpacing: 0.5)),
                      ),
                    ),
                    const SizedBox(height: 24),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
