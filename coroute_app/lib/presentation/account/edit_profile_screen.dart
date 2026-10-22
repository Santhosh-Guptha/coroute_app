import 'package:flutter/material.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/ui.dart';
import 'profile_form.dart';

/// Edit your profile: name, mobile number, bike, emergency contact, optional
/// medical info and whether you receive emergency texts from your group.
/// Opened from the Profile tab, the ride start alert and the pre-ride checklist.
/// Pops with `true` after a successful save.
class EditProfileScreen extends StatelessWidget {
  const EditProfileScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      resizeToAvoidBottomInset: true,
      backgroundColor: AppTheme.bg,
      body: SafeArea(
        bottom: false,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 600),
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
                  child: DsScreenHeader(
                    title: 'Edit profile',
                    subtitle: 'How your group reaches you',
                    onBack: () => Navigator.maybePop(context),
                  ),
                ),
                Expanded(
                  child: ProfileForm(onSaved: () => Navigator.of(context).pop(true)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
