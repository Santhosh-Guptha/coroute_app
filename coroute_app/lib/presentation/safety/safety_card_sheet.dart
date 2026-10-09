import 'package:flutter/material.dart';
import '../../core/l10n/l10n.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/ui.dart';
import '../../data/models/medical_info.dart';
import '../ride/incident_banner.dart' show dialNumber;

/// The rider safety card (3.16, item 6): blood group, allergies, notes for a
/// doctor and the emergency contact in large text, so a responder can read
/// it at arm's length. Opened from Profile ("Show my safety card") and from
/// the incident and assistance sheets while an alert is open (same
/// visibility rules as the medical info: the gateway only sends it then).
/// Texts follow the rider's language.
class SafetyCardSheet extends StatelessWidget {
  final String name;
  final MedicalInfo? medical;
  final String contactName;
  final String contactPhone;

  /// My own card: no Call button, a footer about who sees it.
  final bool mine;

  const SafetyCardSheet({
    super.key,
    required this.name,
    this.medical,
    this.contactName = '',
    this.contactPhone = '',
    this.mine = false,
  });

  static Future<void> show(
    BuildContext context, {
    required String name,
    MedicalInfo? medical,
    String contactName = '',
    String contactPhone = '',
    bool mine = false,
  }) {
    return showAppSheet<void>(
      context,
      isScrollControlled: true,
      builder: (_) => SingleChildScrollView(
        child: SafetyCardSheet(name: name, medical: medical, contactName: contactName, contactPhone: contactPhone, mine: mine),
      ),
    );
  }

  /// "Priya, +91 91234 56780", "+91 91234 56780" or "" (pure, for tests).
  static String contactText(String contactName, String contactPhone) {
    final n = contactName.trim();
    final p = contactPhone.trim();
    if (n.isEmpty && p.isEmpty) return '';
    if (n.isEmpty) return p;
    if (p.isEmpty) return n;
    return '$n, $p';
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<String>(
      valueListenable: L10n.changes,
      builder: (context, _, _) => _body(context),
    );
  }

  Widget _body(BuildContext context) {
    final m = medical ?? const MedicalInfo();
    final none = L10n.t('card.none');
    final blood = m.bloodGroup.trim();
    final allergies = m.allergies.trim();
    final notes = m.notes.trim();
    final contact = contactText(contactName, contactPhone);
    final phone = contactPhone.trim();
    final first = name.trim().isEmpty ? '' : name.trim().split(' ').first;
    final Color red = StatusColors.critical;

    Widget row(IconData icon, String label, String value, {bool big = false}) {
      return Padding(
        padding: const EdgeInsets.only(bottom: Space.s16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Icon(icon, size: 24, color: AppTheme.textSecondary),
            ),
            const SizedBox(width: Space.s12),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label, maxLines: 2, overflow: TextOverflow.ellipsis, style: AppText.label),
                  const SizedBox(height: 2),
                  Text(
                    value.isEmpty ? none : value,
                    maxLines: big ? 1 : 6,
                    overflow: TextOverflow.ellipsis,
                    style: big
                        ? AppText.metric.copyWith(color: value.isEmpty ? AppTheme.textMuted : AppTheme.textPrimary)
                        : AppText.title.copyWith(color: value.isEmpty ? AppTheme.textMuted : AppTheme.textPrimary, height: 1.3),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(color: red.withOpacity(0.14), shape: BoxShape.circle),
              child: Icon(Icons.medical_information_rounded, color: red, size: 28),
            ),
            const SizedBox(width: Space.s12),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Semantics(
                    header: true,
                    child: Text(L10n.t('card.title'), maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.title.copyWith(fontWeight: FontWeight.w700)),
                  ),
                  if (name.trim().isNotEmpty) Text(name.trim(), maxLines: 2, overflow: TextOverflow.ellipsis, style: AppText.body),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: Space.s24),
        row(Icons.bloodtype_rounded, L10n.t('card.blood'), blood, big: true),
        row(Icons.warning_amber_rounded, L10n.t('card.allergies'), allergies),
        row(Icons.notes_rounded, L10n.t('card.notes'), notes),
        row(Icons.contact_emergency_rounded, L10n.t('card.contact'), contact),
        if (!mine && phone.isNotEmpty) ...[
          FilledButton.icon(
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(56)),
            onPressed: () => dialNumber(context, phone),
            icon: const Icon(Icons.call_rounded),
            label: Text(
              L10n.t('card.call', {'name': contactName.trim().isEmpty ? (first.isEmpty ? '' : first) : contactName.trim()}).trim(),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(height: Space.s12),
        ],
        Text(L10n.t('card.footer'), maxLines: 4, overflow: TextOverflow.ellipsis, style: AppText.caption),
        const SizedBox(height: Space.s8),
        OutlinedButton(
          style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
          onPressed: () => Navigator.of(context).maybePop(),
          child: Text(L10n.t('card.close'), maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
      ],
    );
  }
}
