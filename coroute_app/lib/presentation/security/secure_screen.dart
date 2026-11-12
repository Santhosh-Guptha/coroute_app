import 'package:flutter/widgets.dart';

import '../../data/services/app_security_native.dart';

/// Round 4: sets FLAG_SECURE (no screenshots or screen recording, blank in Recents) while this widget is shown.
/// Used ONLY on sensitive screens: sign-in, the e-mail code entry, the Medical ID edit form and the 2-step prompt.
/// Never on the map or ride screens (riders share screenshots of rides, and a support photo must stay possible).
class SecureScreen extends StatefulWidget {
  const SecureScreen({super.key, required this.child});

  final Widget child;

  @override
  State<SecureScreen> createState() => _SecureScreenState();
}

class _SecureScreenState extends State<SecureScreen> {
  @override
  void initState() {
    super.initState();
    SecureWindow.acquire();
  }

  @override
  void dispose() {
    SecureWindow.release();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
