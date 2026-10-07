import 'package:flutter/material.dart';
import '../../core/theme/app_theme.dart';
import 'profile_form.dart';

/// Edit your profile: name, mobile number, bike and emergency contact.
/// Opened from the Profile tab, the ride start alert and the pre-ride checklist.
/// Pops with `true` after a successful save.
class EditProfileScreen extends StatelessWidget {
  const EditProfileScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.obsidianVoid,
      appBar: AppBar(title: const Text('Edit profile')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 600),
          child: ProfileForm(onSaved: () => Navigator.of(context).pop(true)),
        ),
      ),
    );
  }
}
