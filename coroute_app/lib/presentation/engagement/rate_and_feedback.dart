import 'package:flutter/material.dart';

import '../../core/l10n/l10n.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/ui.dart';
import '../../data/services/api_client.dart';
import '../../data/services/engagement_service.dart';
import '../../data/services/meta_service.dart';
import '../../domain/engagement/engagement_config.dart';

/// 3.55 "Rate CoRoute" and "Send feedback" (docs/features_355/ratings_reviews.md): the permanent
/// rows in Settings and Profile. Two separate rows, never one question that sorts riders: "Rate
/// CoRoute" goes straight to Google Play for everyone; "Send feedback" is a private message to the
/// CoRoute team. Neither asks how the rider feels first, and nothing is offered for a rating.
class RateAndFeedback {
  RateAndFeedback._();

  static EngagementConfig get _cfg => EngagementService.instance?.config ?? EngagementConfig.defaults;

  static String get rateTitle => _cfg.text('rateTitle', L10n.current);
  static String get rateSubtitle => _cfg.text('rateSubtitle', L10n.current);
  static String get feedbackTitle => _cfg.text('feedbackTitle', L10n.current);
  static String get feedbackSubtitle => _cfg.text('feedbackSubtitle', L10n.current);

  /// The explicit row: Google Play's in-app review card, else the store page.
  static Future<void> rate(BuildContext context) async {
    final ok = await EngagementService.rateFromRow();
    if (!ok && context.mounted) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(const SnackBar(content: Text('Google Play is not available on this phone.')));
    }
  }

  static Future<void> openFeedback(BuildContext context) =>
      Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const SendFeedbackScreen()));
}

/// A short private message to the CoRoute team (POST /api/me/feedback, shown in the web admin).
class SendFeedbackScreen extends StatefulWidget {
  const SendFeedbackScreen({super.key});

  static const Map<String, String> topicLabels = {
    'general': 'General',
    'bug': 'Something is wrong',
    'idea': 'An idea',
    'ride': 'Rides',
    'places': 'Places',
    'other': 'Other',
  };

  @override
  State<SendFeedbackScreen> createState() => _SendFeedbackScreenState();
}

class _SendFeedbackScreenState extends State<SendFeedbackScreen> {
  final TextEditingController _text = TextEditingController();
  String _topic = 'general';
  bool _contact = false;
  bool _sending = false;
  String? _error;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final msg = _text.text.trim();
    if (msg.length < EngagementService.feedbackMin) {
      setState(() => _error = 'Please write at least ${EngagementService.feedbackMin} characters.');
      return;
    }
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      final svc = EngagementService.instance;
      if (svc == null) throw const ApiException(0, 'Not available right now. Please try again.');
      final build = MetaService.currentVersion.isEmpty ? '' : '${MetaService.currentVersion}+${MetaService.currentBuild}';
      await svc.sendFeedback(message: msg, topic: _topic, contactOk: _contact, appVersion: build);
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(const SnackBar(content: Text('Thanks. The CoRoute team reads every message.')));
      Navigator.of(context).maybePop();
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (_) {
      if (mounted) setState(() => _error = 'Could not send. Check your connection and try again.');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final title = RateAndFeedback.feedbackTitle;
    return Scaffold(
      backgroundColor: AppTheme.background,
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(Space.s16),
          children: [
            DsScreenHeader(title: title, onBack: () => Navigator.maybePop(context)),
            const SizedBox(height: Space.s8),
            Text(RateAndFeedback.feedbackSubtitle, style: AppText.label),
            const SizedBox(height: Space.s16),
            Wrap(
              spacing: Space.s8,
              runSpacing: Space.s8,
              children: [
                for (final t in EngagementService.feedbackTopics)
                  ChoiceChip(
                    key: ValueKey('feedback_topic:$t'),
                    label: Text(SendFeedbackScreen.topicLabels[t] ?? t),
                    selected: _topic == t,
                    selectedColor: AppTheme.primarySoft,
                    onSelected: (_) => setState(() => _topic = t),
                  ),
              ],
            ),
            const SizedBox(height: Space.s16),
            TextField(
              key: const ValueKey('feedback_text'),
              controller: _text,
              minLines: 4,
              maxLines: 8,
              maxLength: EngagementService.feedbackMax,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(hintText: 'What should we fix or improve?'),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _contact,
              onChanged: (v) => setState(() => _contact = v),
              title: Text('You may reply by e-mail', style: AppText.body),
              subtitle: Text('Off: your message is sent without your e-mail.', style: AppText.caption),
            ),
            if (_error != null) Padding(padding: const EdgeInsets.only(bottom: Space.s8), child: Text(_error!, style: AppText.label.copyWith(color: AppTheme.danger))),
            DsButton(
              key: const ValueKey('feedback_send'),
              label: _sending ? 'Sending…' : 'Send',
              icon: Icons.send_rounded,
              onPressed: _sending ? null : _send,
            ),
          ],
        ),
      ),
    );
  }
}
