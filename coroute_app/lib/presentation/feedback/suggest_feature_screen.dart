import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_theme.dart';
import '../../core/ui/ui.dart';
import '../../data/services/api_client.dart';
import '../../data/services/auth_service.dart';
import '../../data/services/meta_service.dart';

/// What an idea is about (the gateway's feedback `topic`, gateway/src/routes.js FEEDBACK_TOPICS).
enum IdeaTopic {
  safety('safety-idea', 'Safety idea'),
  group('group-riding', 'Group riding'),
  map('map-navigation', 'Map & navigation'),
  other('other', 'Other');

  const IdeaTopic(this.wire, this.label);
  final String wire;
  final String label;
}

/// Sends one idea; throws [ApiException] (or anything else) when it could not be sent.
typedef IdeaSender = Future<void> Function(Map<String, dynamic> body);

/// "Suggest a safety feature": Profile > Help and the ride analytics screen.
/// Sent to the same feedback endpoint as "Report a problem", with a topic.
/// The e-mail goes along only when the rider turns on "Contact me".
class SuggestFeatureScreen extends StatelessWidget {
  const SuggestFeatureScreen({super.key});

  static Future<void> open(BuildContext context) =>
      Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const SuggestFeatureScreen()));

  @override
  Widget build(BuildContext context) {
    AuthService? auth;
    try {
      auth = context.read<AuthService>();
    } catch (_) {
      auth = null;
    }
    final api = context.read<ApiClient>();
    final device = kIsWeb ? 'web' : '${Platform.operatingSystem} ${Platform.operatingSystemVersion}';
    return Scaffold(
      resizeToAvoidBottomInset: true,
      backgroundColor: AppTheme.bg,
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: ListView(
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              padding: dsScreenPadding,
              children: [
                DsScreenHeader(title: 'Suggest a safety feature', onBack: () => Navigator.maybePop(context)),
                const SizedBox(height: 18),
                SuggestFeatureForm(
                  email: auth?.currentUserEmail ?? '',
                  name: auth?.currentUserName ?? '',
                  send: (body) async {
                    await api.post('/feedback', {
                      ...body,
                      'appVersion': '${MetaService.currentVersion}+${MetaService.currentBuild}',
                      'device': device,
                    });
                  },
                  onDone: () => Navigator.maybePop(context),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class SuggestFeatureForm extends StatefulWidget {
  final IdeaSender send;

  /// The account e-mail, offered by "Contact me" (empty: the switch is off and disabled).
  final String email;
  final String name;
  final VoidCallback? onDone;

  const SuggestFeatureForm({super.key, required this.send, this.email = '', this.name = '', this.onDone});

  static const int maxLength = 500;

  /// The gateway asks for a sentence or two.
  static const int minLength = 20;

  static const String thanks = 'Thanks! Ideas like yours shape what we build next.';

  /// The request body (without app version and device). Pure, for tests.
  static Map<String, dynamic> bodyOf({
    required IdeaTopic topic,
    required String message,
    required bool contact,
    required String email,
    required String name,
    required int openedAt,
  }) =>
      {
        'topic': topic.wire,
        'message': message.trim(),
        't': openedAt,
        'contact': contact && email.isNotEmpty,
        if (contact && email.isNotEmpty) 'email': email,
        if (contact && email.isNotEmpty && name.isNotEmpty) 'name': name,
      };

  @override
  State<SuggestFeatureForm> createState() => _SuggestFeatureFormState();
}

class _SuggestFeatureFormState extends State<SuggestFeatureForm> {
  final _message = TextEditingController();
  final int _openedAt = DateTime.now().millisecondsSinceEpoch;
  IdeaTopic _topic = IdeaTopic.safety;
  bool _contact = false;
  bool _busy = false;
  bool _sent = false;
  String? _error;

  @override
  void dispose() {
    _message.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final text = _message.text.trim();
    if (text.length < SuggestFeatureForm.minLength) {
      setState(() => _error = 'A sentence or two helps us understand it (at least ${SuggestFeatureForm.minLength} characters).');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.send(SuggestFeatureForm.bodyOf(
        topic: _topic,
        message: text,
        contact: _contact,
        email: widget.email,
        name: widget.name,
        openedAt: _openedAt,
      ));
      if (!mounted) return;
      setState(() => _sent = true);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.statusCode == 0 ? 'You seem to be offline. Please try again later.' : e.message);
    } catch (_) {
      if (mounted) setState(() => _error = 'Could not send right now. Please try again later.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_sent) {
      return DsCard(
        key: const Key('idea_thanks'),
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            Icon(Icons.lightbulb_rounded, size: 40, color: AppTheme.accentText),
            const SizedBox(height: Space.s12),
            Text(SuggestFeatureForm.thanks, textAlign: TextAlign.center, style: AppText.title),
            if (widget.onDone != null) ...[
              const SizedBox(height: Space.s16),
              DsButton(label: 'Done', onPressed: widget.onDone),
            ],
          ],
        ),
      );
    }
    final hasEmail = widget.email.isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('What would make your rides safer or easier? We read every idea.', style: AppText.label),
        const SizedBox(height: Space.s16),
        Semantics(
          header: true,
          child: Text('Topic', style: AppText.body.copyWith(fontWeight: FontWeight.w600)),
        ),
        const SizedBox(height: Space.s8),
        Wrap(
          spacing: Space.s8,
          runSpacing: Space.s8,
          children: [
            for (final t in IdeaTopic.values)
              ChoiceChip(
                key: Key('idea_topic_${t.name}'),
                label: Text(t.label),
                selected: _topic == t,
                onSelected: _busy ? null : (_) => setState(() => _topic = t),
              ),
          ],
        ),
        const SizedBox(height: Space.s16),
        TextField(
          key: const Key('idea_message'),
          controller: _message,
          minLines: 4,
          maxLines: 8,
          maxLength: SuggestFeatureForm.maxLength,
          enabled: !_busy,
          textCapitalization: TextCapitalization.sentences,
          style: AppText.body,
          decoration: InputDecoration(hintText: 'Your idea', counterStyle: AppText.caption),
        ),
        DsSwitchRow(
          label: 'Contact me about this idea',
          subtitle: hasEmail ? 'We may e-mail ${widget.email}. Off: sent without your e-mail.' : 'Add an e-mail to your profile to turn this on.',
          value: _contact && hasEmail,
          onChanged: hasEmail && !_busy ? (v) => setState(() => _contact = v) : null,
          divider: false,
        ),
        if (_error != null) ...[
          const SizedBox(height: Space.s8),
          RideAlert(tier: AlertTier.important, title: _error!),
        ],
        const SizedBox(height: Space.s16),
        DsButton(
          key: const Key('idea_send'),
          label: _busy ? 'Sending...' : 'Send idea',
          icon: _busy ? null : Icons.send_rounded,
          onPressed: _busy ? null : _submit,
        ),
      ],
    );
  }
}
