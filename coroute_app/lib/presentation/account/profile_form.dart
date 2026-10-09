import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../../core/constants/app_constants.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/ui.dart';
import '../../core/constants/safety_constants.dart';
import '../../data/models/medical_info.dart';
import '../../data/services/auth_service.dart';
import '../../data/services/settings_service.dart';
import '../safety/safety_card_sheet.dart';
import '../safety/safety_settings_sheet.dart';

/// The one profile form: name, mobile number, bike (or pillion), the
/// emergency contact, optional medical info ("Notes for a doctor", the
/// safety card), the tank range, the language and the emergency text opt-out.
/// Used by [EditProfileScreen] and by the forced CompleteProfileScreen after
/// a Google sign-in.
///
/// It is a scrolling list itself, so place it directly in a Scaffold body.
class ProfileForm extends StatefulWidget {
  /// Shown above the fields (for example a short notice).
  final Widget? header;
  final String saveLabel;

  /// Called after the server accepted the change.
  final VoidCallback? onSaved;

  const ProfileForm({super.key, this.header, this.saveLabel = 'Save', this.onSaved});

  /// The medical notes label (3.16: "Notes for a doctor") and the safety card row.
  static const String notesLabel = 'Notes for a doctor';
  static const String safetyCardLabel = 'Show my safety card';

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

  /// Longest allergies and notes texts (same limits as the gateway).
  static const int allergiesMax = 120;
  static const int medicalNotesMax = 200;

  /// Blood group choices: "" (not set) and the eight groups.
  static List<String> get bloodGroupChoices => ['', ...MedicalInfo.bloodGroups];

  /// What the profile form sends for medical info and the text opt-out. With
  /// [loaded] (the server sent the current values) everything is sent; before
  /// that only what the rider changed, so an outage never clears saved info.
  static ({String? bloodGroup, String? allergies, String? medicalNotes, bool? smsOptOut}) medicalPatch({
    required bool loaded,
    required String bloodGroup,
    required String allergies,
    required String notes,
    required bool smsOptOut,
    String initialBloodGroup = '',
    String initialAllergies = '',
    String initialNotes = '',
    bool initialSmsOptOut = false,
  }) {
    String? pick(String now, String before) => (loaded || now.trim() != before.trim()) ? now.trim() : null;
    return (
      bloodGroup: pick(bloodGroup, initialBloodGroup),
      allergies: pick(allergies, initialAllergies),
      medicalNotes: pick(notes, initialNotes),
      smsOptOut: (loaded || smsOptOut != initialSmsOptOut) ? smsOptOut : null,
    );
  }

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
  final _allergies = TextEditingController();
  final _notes = TextEditingController();

  String _bloodGroup = '';
  bool _smsOptOut = false;
  bool _medicalLoaded = false;
  String _initialBlood = '', _initialAllergies = '', _initialNotes = '';
  bool _initialOptOut = false;
  bool _responderMedical = false;
  bool _initialResponderMedical = false;
  bool _netLoaded = false;
  late List<String> _bloodChoices;

  late List<String> _types;
  late String _vehicle;
  bool _pillion = false;
  bool _busy = false;
  String? _error;
  bool _customFuel = false;
  final _fuel = TextEditingController();

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

    _medicalLoaded = auth.medicalLoaded;
    _initialBlood = auth.bloodGroup.trim();
    _initialAllergies = auth.allergies;
    _initialNotes = auth.medicalNotes;
    _initialOptOut = auth.smsOptOut;
    _bloodChoices = ProfileForm.bloodGroupChoices;
    if (!_bloodChoices.contains(_initialBlood)) _bloodChoices = [..._bloodChoices, _initialBlood];
    _bloodGroup = _initialBlood;
    _allergies.text = _initialAllergies;
    _notes.text = _initialNotes;
    _smsOptOut = _initialOptOut;
    _netLoaded = auth.netLoaded;
    _initialResponderMedical = auth.responderMedical;
    _responderMedical = _initialResponderMedical;
  }

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    _vehicleNo.dispose();
    _contactName.dispose();
    _contactPhone.dispose();
    _allergies.dispose();
    _notes.dispose();
    _fuel.dispose();
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
    final medical = ProfileForm.medicalPatch(
      loaded: _medicalLoaded,
      bloodGroup: _bloodGroup,
      allergies: _allergies.text,
      notes: _notes.text,
      smsOptOut: _smsOptOut,
      initialBloodGroup: _initialBlood,
      initialAllergies: _initialAllergies,
      initialNotes: _initialNotes,
      initialSmsOptOut: _initialOptOut,
    );
    final ok = await auth.updateProfile(
      name: _name.text.trim(),
      phone: _phone.text.trim(),
      vehicleType: _pillion ? ProfileForm.pillionType : _vehicle,
      vehicleNo: _pillion ? ProfileForm.pillionPlate : _vehicleNo.text.trim().toUpperCase(),
      emergencyContact: _contactPhone.text.trim(),
      emergencyContactName: _contactName.text.trim(),
      bloodGroup: medical.bloodGroup,
      allergies: medical.allergies,
      medicalNotes: medical.medicalNotes,
      smsOptOut: medical.smsOptOut,
      // Sent when the server knows the switch, or when the rider changed it (older callers never clear it).
      responderMedical: (_netLoaded || _responderMedical != _initialResponderMedical) ? _responderMedical : null,
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

  Widget _section(String text, {String? subtitle}) => Padding(
        padding: const EdgeInsets.only(top: Space.s24, bottom: Space.s8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Semantics(header: true, child: Text(text, style: AppText.label)),
            if (subtitle != null) ...[
              const SizedBox(height: Space.s4),
              Text(subtitle, style: AppText.caption),
            ],
          ],
        ),
      );

  /// Tank range (3.16, item 2) and the safety language (item 23); saved at once
  /// in the phone's settings, not with the profile. Hidden when no SettingsService.
  List<Widget> _rideAndLanguage() {
    final s = Provider.of<SettingsService?>(context);
    if (s == null) return const [];
    final fuel = s.fuelRangeKm;
    final isChoice = SafetySettingsSheet.fuelChoices.contains(fuel);
    return [
      _section('Ride'),
      FuelRangeField(
        value: fuel,
        custom: _customFuel || (!isChoice && fuel > 0),
        controller: _fuel,
        onChoice: (v) {
          setState(() => _customFuel = false);
          s.setFuelRangeKm(v);
        },
        onCustom: () {
          _fuel.text = isChoice ? '' : '$fuel';
          setState(() => _customFuel = true);
        },
        onSave: () {
          final v = int.tryParse(_fuel.text.trim()) ?? 0;
          s.setFuelRangeKm(v.clamp(0, SafetyConstants.fuelMaxRangeKm));
          setState(() => _customFuel = false);
        },
      ),
      _section('Language'),
      LanguagePicker(value: s.language, onChanged: (l) => s.setLanguage(l)),
    ];
  }

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
        _section('Medical info (optional)', subtitle: 'Shown to your ride group only while your SOS or crash alert is open.'),
        const SizedBox(height: Space.s12),
        InputDecorator(
          decoration: _dec('Blood group', Icons.bloodtype_rounded),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<String>(
              key: const ValueKey('bloodGroup'),
              value: _bloodGroup,
              isDense: true,
              isExpanded: true,
              dropdownColor: AppTheme.slateCard,
              style: AppText.body,
              items: [
                for (final g in _bloodChoices)
                  DropdownMenuItem(value: g, child: Text(g.isEmpty ? 'Not set' : g, maxLines: 1, overflow: TextOverflow.ellipsis)),
              ],
              onChanged: _busy ? null : (v) => setState(() => _bloodGroup = v ?? ''),
            ),
          ),
        ),
        const SizedBox(height: Space.s12),
        TextField(
          key: const ValueKey('allergies'),
          controller: _allergies,
          maxLength: ProfileForm.allergiesMax,
          inputFormatters: [FilteringTextInputFormatter.deny(RegExp(r'[\u0000-\u001F\u007F]'))],
          textCapitalization: TextCapitalization.sentences,
          style: AppText.body,
          decoration: _dec('Allergies', Icons.warning_amber_rounded, hint: 'e.g. penicillin'),
        ),
        const SizedBox(height: Space.s8),
        TextField(
          key: const ValueKey('medicalNotes'),
          controller: _notes,
          maxLength: ProfileForm.medicalNotesMax,
          minLines: 1,
          maxLines: 3,
          keyboardType: TextInputType.text,
          inputFormatters: [FilteringTextInputFormatter.deny(RegExp(r'[\u0000-\u001F\u007F]'))],
          textCapitalization: TextCapitalization.sentences,
          style: AppText.body,
          decoration: _dec(ProfileForm.notesLabel, Icons.medical_information_rounded, hint: 'e.g. diabetic, carries insulin'),
        ),
        const SizedBox(height: Space.s8),
        OutlinedButton.icon(
          key: const ValueKey('safetyCard'),
          style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
          onPressed: () => SafetyCardSheet.show(
            context,
            name: _name.text.trim(),
            medical: MedicalInfo(bloodGroup: _bloodGroup, allergies: _allergies.text.trim(), notes: _notes.text.trim()),
            contactName: _contactName.text.trim(),
            contactPhone: _contactPhone.text.trim(),
            mine: true,
          ),
          icon: const Icon(Icons.badge_rounded),
          label: const Text(ProfileForm.safetyCardLabel, maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
        SwitchListTile(
          key: const ValueKey('responderMedical'),
          contentPadding: EdgeInsets.zero,
          value: _responderMedical,
          onChanged: _busy ? null : (v) => setState(() => _responderMedical = v),
          title: Text('Share with a rider from another group who comes to help me', style: AppText.body),
          subtitle: Text('Only after they accept to help, only while your alert is open. Off by default.', style: AppText.caption),
        ),
        ..._rideAndLanguage(),
        _section('Emergency texts'),
        // Shown as a positive choice (on = receive); stored as the gateway's smsOptOut.
        SwitchListTile(
          key: const ValueKey('smsReceive'),
          contentPadding: EdgeInsets.zero,
          value: !_smsOptOut,
          onChanged: _busy ? null : (v) => setState(() => _smsOptOut = !v),
          title: Text('Receive emergency texts from my ride group', style: AppText.body),
          subtitle: Text(
            'A rider with no internet can text you where they are. When off, your number is not used for these texts.',
            style: AppText.caption,
          ),
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
