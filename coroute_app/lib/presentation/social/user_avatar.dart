import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_theme.dart';
import '../../core/ui/ui.dart';
import '../../data/services/api_client.dart';
import '../../domain/social/username_rules.dart';

/// 3.55 profile picture: the rider's photo (served by the gateway to signed-in riders only) or
/// their initials in a circle when there is none, it fails to load, or photos are switched off.
class UserAvatar extends StatelessWidget {
  /// Name or username the initials come from.
  final String label;

  /// `/api/avatars/<id>` from the gateway, or null.
  final String? avatarUrl;
  final double size;
  final bool filled;

  const UserAvatar({super.key, required this.label, this.avatarUrl, this.size = 44, this.filled = false});

  @override
  Widget build(BuildContext context) {
    final fallback = DsAvatar(avatarInitials(label), size: size, filled: filled);
    final url = avatarUrl;
    final api = context.read<ApiClient?>();
    if (url == null || api == null || !url.startsWith('/api/')) {
      return Semantics(label: label, image: true, excludeSemantics: true, child: fallback);
    }
    final px = (size * MediaQuery.devicePixelRatioOf(context)).round();
    return Semantics(
      label: label,
      image: true,
      excludeSemantics: true,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: AppTheme.accentText, width: size >= 44 ? 3 : 2)),
        child: ClipOval(
          child: Image.network(
            api.apiUrlOf(url.substring(4)),
            headers: api.authHeaders,
            width: size,
            height: size,
            cacheWidth: px,
            fit: BoxFit.cover,
            gaplessPlayback: true,
            errorBuilder: (_, _, _) => fallback,
          ),
        ),
      ),
    );
  }
}
