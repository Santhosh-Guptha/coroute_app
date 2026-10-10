import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/ui_tokens.dart';
import '../../data/local/emergency_corridor_store.dart';
import '../../data/local/ice_profile_store.dart';
import '../../data/models/ice_profile.dart';

/// High-visibility offline ICE (In Case of Emergency) First-Responder Medical Card (REQ-02).
///
/// Designed with stark red-and-white high-contrast visual hierarchy for on-scene
/// first responders, paramedics, and bystanders during zero-connectivity emergencies.
///
/// Presents blood group, allergies, medications, emergency contacts, organ donor status,
/// and the 2 closest offline corridor hospitals/trauma centers with bearing and distance.
class IceMedicalCard extends StatefulWidget {
  final double lat;
  final double lng;
  final double? altitudeM;
  final String? lastKnownLocation;
  final IceProfile? initialProfile;
  final EmergencyCorridorStore? store;
  final VoidCallback? onDismiss;

  const IceMedicalCard({
    super.key,
    required this.lat,
    required this.lng,
    this.altitudeM,
    this.lastKnownLocation,
    this.initialProfile,
    this.store,
    this.onDismiss,
  });

  @override
  State<IceMedicalCard> createState() => _IceMedicalCardState();
}

class _IceMedicalCardState extends State<IceMedicalCard> {
  late final EmergencyCorridorStore _store = widget.store ?? EmergencyCorridorStore();
  IceProfile _profile = IceProfile.empty;
  List<NearbyEmergencyPlace> _nearbyHospitals = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    final loadedProfile = widget.initialProfile ?? await IceProfileStore.load();
    List<NearbyEmergencyPlace> hospitals = const [];

    if (widget.lat != 0.0 || widget.lng != 0.0) {
      hospitals = await _store.getClosestHospitals(widget.lat, widget.lng, limit: 2);
    }

    if (mounted) {
      setState(() {
        _profile = loadedProfile;
        _nearbyHospitals = hospitals;
        _loading = false;
      });
    }
  }

  Future<void> _makeCall(String number) async {
    final clean = number.replaceAll(RegExp(r'[^0-9+]'), '');
    if (clean.isEmpty) return;
    final uri = Uri(scheme: 'tel', path: clean);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri);
    }
  }

  Future<void> _sendSms(String number) async {
    final clean = number.replaceAll(RegExp(r'[^0-9+]'), '');
    if (clean.isEmpty) return;
    final body = 'EMERGENCY: Accident at Lat ${widget.lat.toStringAsFixed(5)}, Lng ${widget.lng.toStringAsFixed(5)}. Need assistance.';
    final uri = Uri(scheme: 'sms', path: clean, queryParameters: {'body': body});
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return Container(
        padding: const EdgeInsets.all(Space.s16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: Radii.mdAll,
          border: Border.all(color: AppTheme.laserRed, width: 2.5),
        ),
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(Space.s24),
            child: CircularProgressIndicator(color: AppTheme.laserRed),
          ),
        ),
      );
    }

    final hasBlood = _profile.bloodGroup.isNotEmpty;
    final bloodDisplay = hasBlood ? _profile.bloodGroup.toUpperCase() : 'UNKNOWN';
    final hasAllergies = _profile.allergies.isNotEmpty;
    final hasMedications = _profile.medications.isNotEmpty;
    final hasInsurance = _profile.insurancePolicyNumber.isNotEmpty;
    final contactName = _profile.emergencyContactName;
    final contactPhone = _profile.emergencyContactPhone;
    final hasContact = contactPhone.isNotEmpty;

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: Radii.mdAll,
        border: Border.all(color: AppTheme.laserRed, width: 3.0),
        boxShadow: const [
          BoxShadow(
            color: Colors.black45,
            blurRadius: 16,
            offset: Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header Red Banner
          Container(
            padding: const EdgeInsets.symmetric(horizontal: Space.s16, vertical: Space.s12),
            color: AppTheme.laserRed,
            child: Row(
              children: [
                const Icon(Icons.medical_services_rounded, color: Colors.white, size: 28),
                const SizedBox(width: Space.s12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'FIRST RESPONDER MEDICAL CARD',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                          fontWeight: FontWeight.w900,
                          letterSpacing: 0.8,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '100% Offline Emergency Telemetry Pack',
                        style: TextStyle(
                          color: Colors.white.withOpacity(0.9),
                          fontSize: 11,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
                if (widget.onDismiss != null)
                  IconButton(
                    icon: const Icon(Icons.close_rounded, color: Colors.white),
                    onPressed: widget.onDismiss,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                  ),
              ],
            ),
          ),

          Padding(
            padding: const EdgeInsets.all(Space.s16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Blood Group & Organ Donor Badges
                Row(
                  children: [
                    Expanded(
                      flex: 3,
                      child: Container(
                        padding: const EdgeInsets.symmetric(vertical: Space.s12, horizontal: Space.s8),
                        decoration: BoxDecoration(
                          color: const Color(0xFFFFEBEE),
                          borderRadius: Radii.smAll,
                          border: Border.all(color: AppTheme.laserRed, width: 2),
                        ),
                        child: Column(
                          children: [
                            Text(
                              'BLOOD TYPE',
                              style: TextStyle(
                                color: AppTheme.laserRed,
                                fontSize: 11,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 0.5,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              bloodDisplay,
                              style: TextStyle(
                                color: AppTheme.laserRed,
                                fontSize: 28,
                                fontWeight: FontWeight.w900,
                                height: 1.0,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: Space.s12),
                    Expanded(
                      flex: 4,
                      child: Container(
                        padding: const EdgeInsets.symmetric(vertical: Space.s12, horizontal: Space.s8),
                        decoration: BoxDecoration(
                          color: _profile.organDonor ? const Color(0xFFE8F5E9) : const Color(0xFFF5F5F5),
                          borderRadius: Radii.smAll,
                          border: Border.all(
                            color: _profile.organDonor ? AppTheme.emeraldSafe : Colors.grey.shade400,
                            width: 1.5,
                          ),
                        ),
                        child: Column(
                          children: [
                            Text(
                              'ORGAN DONOR',
                              style: TextStyle(
                                color: _profile.organDonor ? AppTheme.emeraldSafe : Colors.black87,
                                fontSize: 11,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 0.5,
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              _profile.organDonor ? 'YES - DONOR' : 'NOT DECLARED',
                              style: TextStyle(
                                color: _profile.organDonor ? AppTheme.emeraldSafe : Colors.black87,
                                fontSize: 15,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: Space.s12),

                // Critical Medical Notes / Allergies
                if (hasAllergies || hasMedications) ...[
                  Container(
                    padding: const EdgeInsets.all(Space.s12),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFFF8E1),
                      borderRadius: Radii.smAll,
                      border: Border.all(color: AppTheme.hyperAmber, width: 1.5),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (hasAllergies) ...[
                          const Row(
                            children: [
                              Icon(Icons.warning_amber_rounded, color: Colors.black, size: 16),
                              SizedBox(width: 6),
                              Text(
                                'ALLERGIES / CONDITIONS:',
                                style: TextStyle(
                                  color: Colors.black,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 2),
                          Text(
                            _profile.allergies,
                            style: const TextStyle(
                              color: Colors.black,
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          if (hasMedications) const Divider(height: 12, color: Colors.black26),
                        ],
                        if (hasMedications) ...[
                          const Row(
                            children: [
                              Icon(Icons.medication_rounded, color: Colors.black, size: 16),
                              SizedBox(width: 6),
                              Text(
                                'CRITICAL MEDICATIONS:',
                                style: TextStyle(
                                  color: Colors.black,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 2),
                          Text(
                            _profile.medications,
                            style: const TextStyle(
                              color: Colors.black,
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: Space.s12),
                ],

                // Emergency Contact Row
                if (hasContact) ...[
                  Container(
                    padding: const EdgeInsets.all(Space.s12),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF1F8E9),
                      borderRadius: Radii.smAll,
                      border: Border.all(color: AppTheme.emeraldSafe, width: 1.5),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'EMERGENCY CONTACT (ICE):',
                          style: TextStyle(
                            color: Color(0xFF2E7D32),
                            fontSize: 11,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          contactName.isNotEmpty ? '$contactName ($contactPhone)' : contactPhone,
                          style: const TextStyle(
                            color: Colors.black87,
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            Expanded(
                              child: ElevatedButton.icon(
                                onPressed: () => _makeCall(contactPhone),
                                icon: const Icon(Icons.phone_rounded, size: 16),
                                label: const Text('CALL', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800)),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: AppTheme.emeraldSafe,
                                  foregroundColor: Colors.white,
                                  minimumSize: const Size.fromHeight(36),
                                  padding: EdgeInsets.zero,
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: ElevatedButton.icon(
                                onPressed: () => _sendSms(contactPhone),
                                icon: const Icon(Icons.sms_rounded, size: 16),
                                label: const Text('SMS', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800)),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: AppTheme.hyperAmber,
                                  foregroundColor: Colors.black,
                                  minimumSize: const Size.fromHeight(36),
                                  padding: EdgeInsets.zero,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: Space.s12),
                ],

                // Insurance Policy Box
                if (hasInsurance) ...[
                  Row(
                    children: [
                      const Icon(Icons.verified_user_rounded, color: Colors.black54, size: 16),
                      const SizedBox(width: 6),
                      Text(
                        'Insurance: ${_profile.insurancePolicyNumber}',
                        style: const TextStyle(color: Colors.black87, fontSize: 12, fontWeight: FontWeight.w600),
                      ),
                    ],
                  ),
                  const SizedBox(height: Space.s12),
                ],

                // On-scene Location Banner
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: Space.s8),
                  decoration: BoxDecoration(
                    color: const Color(0xFFECEFF1),
                    borderRadius: Radii.smAll,
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.location_on_rounded, color: AppTheme.laserRed, size: 18),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          'Coords: ${widget.lat.toStringAsFixed(5)}, ${widget.lng.toStringAsFixed(5)}${widget.altitudeM != null ? ' (Alt: ${widget.altitudeM!.round()}m)' : ''}',
                          style: const TextStyle(
                            color: Colors.black87,
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            fontFamily: 'monospace',
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: 'Copy location',
                        icon: const Icon(Icons.copy_rounded, size: 16, color: Colors.black54),
                        onPressed: () {
                          Clipboard.setData(ClipboardData(
                            text: 'https://maps.google.com/?q=${widget.lat},${widget.lng}',
                          ));
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('Coordinates copied to clipboard')),
                          );
                        },
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                      ),
                    ],
                  ),
                ),
                if (widget.lastKnownLocation != null && widget.lastKnownLocation!.isNotEmpty) ...[
                  Padding(
                    padding: const EdgeInsets.only(top: 4, left: 4),
                    child: Text(
                      'Last Known Sector: ${widget.lastKnownLocation}',
                      style: const TextStyle(color: Colors.black54, fontSize: 11, fontStyle: FontStyle.italic),
                    ),
                  ),
                ],
                const SizedBox(height: Space.s12),

                // Closest Offline Hospitals & Trauma Centers
                Row(
                  children: [
                    Icon(Icons.local_hospital_rounded, color: AppTheme.laserRed, size: 18),
                    const SizedBox(width: 6),
                    Text(
                      'CLOSEST OFFLINE HOSPITALS:',
                      style: TextStyle(
                        color: AppTheme.laserRed,
                        fontSize: 12,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 0.5,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),

                if (_nearbyHospitals.isEmpty)
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFAFAFA),
                      borderRadius: Radii.smAll,
                      border: Border.all(color: Colors.grey.shade300),
                    ),
                    child: const Text(
                      'Offline hospital catalog empty for current sector. Refer to nearest route waypoint or dial 112 / 108.',
                      style: TextStyle(color: Colors.black54, fontSize: 11),
                    ),
                  )
                else
                  for (final nearby in _nearbyHospitals) ...[
                    Container(
                      margin: const EdgeInsets.only(bottom: 6),
                      padding: const EdgeInsets.all(Space.s8),
                      decoration: BoxDecoration(
                        color: const Color(0xFFFAFAFA),
                        borderRadius: Radii.smAll,
                        border: Border.all(
                          color: nearby.place.isTraumaCenter ? AppTheme.laserRed : Colors.grey.shade300,
                          width: nearby.place.isTraumaCenter ? 1.5 : 1.0,
                        ),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        nearby.place.name,
                                        style: const TextStyle(
                                          color: Colors.black87,
                                          fontSize: 12,
                                          fontWeight: FontWeight.w700,
                                        ),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                    if (nearby.place.isTraumaCenter)
                                      Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                                        decoration: BoxDecoration(
                                          color: AppTheme.laserRed,
                                          borderRadius: const BorderRadius.all(Radius.circular(3)),
                                        ),
                                        child: const Text(
                                          'TRAUMA',
                                          style: TextStyle(
                                            color: Colors.white,
                                            fontSize: 9,
                                            fontWeight: FontWeight.w900,
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  nearby.directionFormatted,
                                  style: const TextStyle(
                                    color: Color(0xFFC62828),
                                    fontSize: 11,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          if (nearby.place.phone.isNotEmpty) ...[
                            const SizedBox(width: Space.s8),
                            IconButton(
                              icon: Icon(Icons.phone_in_talk_rounded, color: AppTheme.emeraldSafe, size: 20),
                              tooltip: 'Call ${nearby.place.name}',
                              onPressed: () => _makeCall(nearby.place.phone),
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
