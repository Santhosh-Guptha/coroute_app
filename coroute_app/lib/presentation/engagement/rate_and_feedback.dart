import 'package:flutter/material.dart';

import '../../core/l10n/l10n.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/ui.dart';
import '../../data/services/api_client.dart';
import '../../data/services/diag_log_service.dart';
import '../../data/services/engagement_service.dart';
import '../../data/services/meta_service.dart';
import '../../domain/engagement/engagement_config.dart';
import '../settings/diagnostics_screen.dart';

/// 3.55 "Rate CoRoute" and "Send feedback" (docs/features_355/ratings_reviews.md): the permanent
/// rows in Profile › Help (only there since Nov 11). Two separate rows, never one question that
/// sorts riders: "Rate CoRoute" goes straight to Google Play for everyone; "Send feedback" is a
/// private message to the CoRoute team. Neither asks how the rider feels first, and nothing is
/// offered for a rating.
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

  /// The one feedback screen (report a problem, suggest a safety feature, other).
  static Future<void> openFeedback(BuildContext context, {FeedbackCategory category = FeedbackCategory.problem}) =>
      Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => SendFeedbackScreen(initial: category)));
}

/// What a message is about. One screen replaces the old "Report a problem", "Suggest a safety
/// feature" and "Send feedback" rows (Nov 11). [topic] is the gateway's /me/feedback topic
/// (gateway/src/engagement.js FEEDBACK_TOPICS).
enum FeedbackCategory {
  problem('bug', 'Report a problem', 'What happened, and on which screen?'),
  safetyIdea('idea', 'Suggest a safety feature', 'What would make your rides safer?'),
  other('other', 'Other', 'Your message');

  const FeedbackCategory(this.topic, this.label, this.hint);
  final String topic;
  final String label;
  final String hint;
}

/// A short private message to the CoRoute team (POST /api/me/feedback, shown in the web admin),
/// with an optional diagnostics log (the same upload as Diagnostics › Send logs). The
/// Diagnostics screen itself is reached from here (its one place in the app).
class SendFeedbackScreen extends StatefulWidget {
  final FeedbackCategory initial;
  const SendFeedbackScreen({super.key, this.initial = FeedbackCategory.problem});

  static const String attachTitle = 'Attach diagnostics log';
  static const String attachSubtitle = 'No messages, names or exact places';
  static const String diagnosticsLink = 'View diagnostics';

  /// The /me/feedback topic for [c] (pure, for tests).
  static String topicFor(FeedbackCategory c) => c.topic;

  @override
  State<SendFeedbackScreen> createState() => _SendFeedbackScreenState();
}

class _SendFeedbackScreenState extends State<SendFeedbackScreen> {
  final TextEditingController _text = TextEditingController();
  late FeedbackCategory _category = widget.initial;
  bool _contact = false;
  bool _attachLog = false;
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
      await svc.sendFeedback(message: msg, topic: SendFeedbackScreen.topicFor(_category), contactOk: _contact, appVersion: build);
      // The log goes only when the rider turned this on; a failed upload never loses the message.
      String? logProblem;
      if (_attachLog) logProblem = await DiagLogService.instance.upload(DiagUploadReason.manual);
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
        content: Text(logProblem == null ? 'Thanks. The CoRoute team reads every message.' : 'Message sent. The log was not: $logProblem'),
      ));
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
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: ListView(
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              padding: dsScreenPadding,
              children: [
                DsScreenHeader(title: title, onBack: () => Navigator.maybePop(context)),
                const SizedBox(height: Space.s16),
                Wrap(
                  spacing: Space.s8,
                  runSpacing: Space.s8,
                  children: [
                    for (final c in FeedbackCategory.values)
                      ChoiceChip(
                        key: ValueKey('feedback_category:${c.name}'),
                        label: Text(c.label),
                        selected: _category == c,
                        showCheckmark: false,
                        selectedColor: AppTheme.primarySoft,
                        onSelected: _sending ? null : (_) => setState(() => _category = c),
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
                  enabled: !_sending,
                  textCapitalization: TextCapitalization.sentences,
                  style: AppText.body,
                  decoration: InputDecoration(hintText: _category.hint, counterStyle: AppText.caption),
                ),
                DsSwitchRow(
                  key: const ValueKey('feedback_attach_log'),
                  label: SendFeedbackScreen.attachTitle,
                  subtitle: SendFeedbackScreen.attachSubtitle,
                  value: _attachLog,
                  onChanged: _sending ? null : (v) => setState(() => _attachLog = v),
                ),
                DsSwitchRow(
                  key: const ValueKey('feedback_contact'),
                  label: 'You may reply by e-mail',
                  subtitle: 'Off: sent without your e-mail',
                  value: _contact,
                  divider: false,
                  onChanged: _sending ? null : (v) => setState(() => _contact = v),
                ),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: Space.s8),
                    child: Text(_error!, style: AppText.label.copyWith(color: AppTheme.danger)),
                  ),
                const SizedBox(height: Space.s16),
                DsButton(
                  key: const ValueKey('feedback_send'),
                  label: _sending ? 'Sending…' : 'Send',
                  icon: Icons.send_rounded,
                  onPressed: _sending ? null : _send,
                ),
                const SizedBox(height: Space.s8),
                TextButton.icon(
                  key: const ValueKey('feedback_diagnostics'),
                  onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const DiagnosticsScreen())),
                  icon: const Icon(Icons.bug_report_outlined, size: 18),
                  label: const Text(SendFeedbackScreen.diagnosticsLink),
                  style: TextButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
