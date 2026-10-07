import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../../core/constants/app_constants.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/ui.dart';
import '../../data/services/auth_service.dart';

/// The one profile form: name, mobile number, bike (or pillion) and the
/// emergency contact. Used by [EditProfileScreen] and by the forced
/// CompleteProfileScreen after a Google sign-in.
///
/// It is a scrolling list itself, so place it directly in a Scaffold body.
class ProfileForm extends StatefulWidget {
  /// Shown above the fields (for example a short notice).
  final Widget? header;
  final String saveLabel;

  /// Called after the server accepted the change.
  final VoidCallback? onSaved;

  const ProfileForm({super.key, this.header, this.saveLabel = 'Save', this.onSaved});

  /// Vehicle choices. Pillion is a switch, not a vehicle.
  static const List<String> vehicleTypes = [
    'Motorcycle (Adv)',
    'Motorcycle (Cruiser)',
    'Motorcycle (Sport)',
    'Motorcycle (Commuter)',
    'Scooter / Maxi',
    'Support car / SUV',
    'Other',
  ];

  /// Stored vehicle type for a pillion passenger (read by the gateway and AuthService.isPillion).
  static const String pillionType = 'Pillion Rider';
  static const String pillionPlate = 'PILLION';

  /// The problem with the entered values, or null when they can be saved.
  static String? validate({
    required String name,
    required String phone,
    required bool pillion,
    required String vehicleNo,
    required String contactName,
    required String contactPhone,
  }) {
    if (name.trim().length < 2) return 'Enter your name (at least 2 letters).';
    if (phone.trim().length < 7) return 'Enter your mobile number so your group can call you.';
    if (!pillion && vehicleNo.trim().length < 3) return 'Enter your bike registration number, or turn on pillion.';
    if (contactName.trim().length < 2) return 'Enter the name of your emergency contact.';
    if (contactPhone.trim().length < 7) return 'Enter the phone number of your emergency contact.';
    return null;
  }

  @override
  State<ProfileForm> createState() => _ProfileFormState();
}

class _ProfileFormState extends State<ProfileForm> {
  final _name = TextEditingController();
  final _phone = TextEditingController();
  final _vehicleNo = TextEditingController();
  final _contactName = TextEditingController();
  final _contactPhone = TextEditingController();

  late List<String> _types;
  late String _vehicle;
  bool _pillion = false;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final auth = context.read<AuthService>();
    _name.text = auth.currentUserName ?? '';
    _phone.text = auth.phone ?? '';
    _pillion = auth.isPillion;
    final plate = auth.vehicleNo ?? '';
    _vehicleNo.text = (_pillion || plate.toUpperCase() == ProfileForm.pillionPlate) ? '' : plate;
    _contactName.text = auth.emergencyContactName ?? '';
    _contactPhone.text = auth.emergencyContact ?? '';

    // Keep a type saved by an older version so saving does not silently change it.
    final current = (auth.vehicleType ?? '').trim();
    _types = List.of(ProfileForm.vehicleTypes);
    if (current.isNotEmpty && current != ProfileForm.pillionType && !_types.contains(current)) {
      _types.insert(_types.length - 1, current);
    }
    _vehicle = _types.contains(current) ? current : _types.first;
  }

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    _vehicleNo.dispose();
    _contactName.dispose();
    _contactPhone.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final problem = ProfileForm.validate(
      name: _name.text,
      phone: _phone.text,
      pillion: _pillion,
      vehicleNo: _vehicleNo.text,
      contactName: _contactName.text,
      contactPhone: _contactPhone.text,
    );
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final auth = context.read<AuthService>();
    final ok = await auth.updateProfile(
      name: _name.text.trim(),
      phone: _phone.text.trim(),
      vehicleType: _pillion ? ProfileForm.pillionType : _vehicle,
      vehicleNo: _pillion ? ProfileForm.pillionPlate : _vehicleNo.text.trim().toUpperCase(),
      emergencyContact: _contactPhone.text.trim(),
      emergencyContactName: _contactName.text.trim(),
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Profile saved.')));
      widget.onSaved?.call();
    } else {
      setState(() => _error = auth.lastProfileError ?? 'Could not save your profile. Check your connection and try again.');
    }
  }

  InputDecoration _dec(String label, IconData icon, {String? hint}) => InputDecoration(
        labelText: label,
        hintText: hint,
        prefixIcon: Icon(icon, color: AppTheme.textSecondary),
        filled: true,
        fillColor: AppTheme.elevatedCard,
        border: const OutlineInputBorder(borderRadius: Radii.mdAll),
      );

  Widget _section(String text) => Padding(
        padding: const EdgeInsets.only(top: Space.s24, bottom: Space.s8),
        child: Semantics(header: true, child: Text(text, style: AppText.label)),
      );

  @override
  Widget build(BuildContext context) {
    final header = widget.header;
    final err = _error;
    return ListView(
      padding: const EdgeInsets.fromLTRB(Space.s16, Space.s12, Space.s16, Space.s32),
      children: [
        ?header,
        if (err != null) ...[
          const SizedBox(height: Space.s12),
          RideAlert(tier: AlertTier.important, title: err),
        ],
        _section('About you'),
        TextField(
          controller: _name,
          inputFormatters: [LengthLimitingTextInputFormatter(AppConstants.maxCallsignLength)],
          textCapitalization: TextCapitalization.words,
          style: AppText.body,
          decoration: _dec('Name', Icons.person_rounded, hint: 'The name your group knows you by'),
        ),
        const SizedBox(height: Space.s12),
        TextField(
          controller: _phone,
          inputFormatters: [LengthLimitingTextInputFormatter(AppConstants.maxPhoneInputLength)],
          keyboardType: TextInputType.phone,
          style: AppText.body,
          decoration: _dec('Mobile number', Icons.phone_rounded, hint: 'e.g. +91 98765 43210'),
        ),
        _section('Your bike'),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: _pillion,
          onChanged: _busy ? null : (v) => setState(() => _pillion = v),
          title: Text('I ride as a pillion', style: AppText.body),
          subtitle: Text('No bike registration needed.', style: AppText.caption),
        ),
        if (!_pillion) ...[
          const SizedBox(height: Space.s8),
          InputDecorator(
            decoration: _dec('Vehicle type', Icons.two_wheeler_rounded),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                value: _vehicle,
                isDense: true,
                isExpanded: true,
                dropdownColor: AppTheme.slateCard,
                style: AppText.body,
                items: [
                  for (final v in _types) DropdownMenuItem(value: v, child: Text(v, maxLines: 1, overflow: TextOverflow.ellipsis)),
                ],
                onChanged: _busy ? null : (v) => setState(() => _vehicle = v ?? _vehicle),
              ),
            ),
          ),
          const SizedBox(height: Space.s12),
          TextField(
            controller: _vehicleNo,
            inputFormatters: [LengthLimitingTextInputFormatter(AppConstants.maxVehicleNoLength)],
            textCapitalization: TextCapitalization.characters,
            style: AppText.body,
            decoration: _dec('Registration number', Icons.pin_rounded, hint: 'e.g. KA 01 AB 1234'),
          ),
        ],
        _section('Emergency contact'),
        Text(
          'Your SOS screen offers one tap to call or message this person.',
          style: AppText.caption,
        ),
        const SizedBox(height: Space.s12),
        TextField(
          controller: _contactName,
          inputFormatters: [LengthLimitingTextInputFormatter(AppConstants.maxContactNameLength)],
          textCapitalization: TextCapitalization.words,
          style: AppText.body,
          decoration: _dec('Contact name', Icons.contact_emergency_rounded, hint: 'e.g. Brother, Spouse'),
        ),
        const SizedBox(height: Space.s12),
        TextField(
          controller: _contactPhone,
          inputFormatters: [LengthLimitingTextInputFormatter(AppConstants.maxPhoneInputLength)],
          keyboardType: TextInputType.phone,
          style: AppText.body,
          decoration: _dec('Contact phone', Icons.phone_in_talk_rounded, hint: 'e.g. +91 91234 56780'),
        ),
        const SizedBox(height: Space.s24),
        FilledButton(
          onPressed: _busy ? null : _save,
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(56)),
          child: _busy
              ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2.5))
              : Text(widget.saveLabel),
        ),
      ],
    );
  }
}
