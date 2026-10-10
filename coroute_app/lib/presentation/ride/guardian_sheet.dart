import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/ui/ui.dart';
import '../../data/services/api_client.dart';
import '../../data/services/convoy_service.dart';

Future<void> showGuardianSheet(
  BuildContext context, {
  required String groupId,
}) => showAppSheet<void>(
  context,
  title: 'Ride Guardian',
  isScrollControlled: true,
  builder: (_) => GuardianSheet(groupId: groupId),
);

class GuardianSheet extends StatelessWidget {
  const GuardianSheet({super.key, required this.groupId});
  final String groupId;
  @override
  Widget build(BuildContext context) {
    final token = context.select<ApiClient, String?>((api) => api.token);
    return _GuardianContent(key: ValueKey((groupId, token)), groupId: groupId);
  }
}

class _GuardianContent extends StatefulWidget {
  const _GuardianContent({super.key, required this.groupId});
  final String groupId;
  @override
  State<_GuardianContent> createState() => _GuardianSheetState();
}

class _GuardianSheetState extends State<_GuardianContent> {
  final _pin = TextEditingController();
  @override
  void dispose() {
    _pin.dispose();
    super.dispose();
  }

  String _level = 'BASIC', _subject = 'PERSONAL';
  bool _groupConsent = false;
  bool _acknowledged = false, _busy = false;
  String? _error, _url;
  List<Map<String, dynamic>> _links = [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _load();
    });
  }

  Future<void> _load() async {
    await _run(() async {
      final consent = await context.read<ApiClient>().get(
        '/guardian/consent/${Uri.encodeComponent(widget.groupId)}',
      );
      if (mounted && consent is Map) _groupConsent = consent['allowed'] == true;
      if (!mounted) return;
      final data = await context.read<ApiClient>().get(
        '/guardian/links/${Uri.encodeComponent(widget.groupId)}',
      );
      if (mounted && data is Map && data['links'] is List) {
        _links = (data['links'] as List)
            .whereType<Map>()
            .map((v) => Map<String, dynamic>.from(v))
            .toList();
      }
    });
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (e) {
      if (mounted) {
        _error = e is ApiException
            ? e.message
            : 'Could not complete the request. Try again.';
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
        });
      }
    }
  }

  Future<void> _create() => _run(() async {
    if (_pin.text.isNotEmpty && !RegExp(r'^[0-9]{4,8}$').hasMatch(_pin.text)) {
      throw const ApiException(400, 'Use a PIN of 4 to 8 digits.');
    }
    final data = await context.read<ApiClient>().post('/guardian/links', {
      if (_pin.text.isNotEmpty) 'pin': _pin.text,
      'groupId': widget.groupId,
      'subject': _subject,
      'level': _level,
      'acknowledged': _acknowledged,
    });
    if (!mounted) return;
    if (data is! Map || data['url'] is! String) {
      throw const FormatException('Invalid link');
    }
    _pin.clear();
    _url = data['url'] as String;
    _links.insert(0, Map<String, dynamic>.from(data)..remove('url'));
  });

  Future<void> _revoke(String id) => _run(() async {
    await context.read<ApiClient>().delete(
      '/guardian/links/${Uri.encodeComponent(id)}',
    );
    if (!mounted) return;
    for (final link in _links) {
      if (link['grantId'] == id) link['status'] = 'REVOKED';
    }
    _url = null;
  });

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'Guardians can view the information you share, but cannot control the ride. Fuel and contacts remain private.',
        ),
        SwitchListTile(
          value: _groupConsent,
          title: const Text('Include me in Guardian group sharing'),
          subtitle: const Text(
            'Allow the lead to share my status, location and emergency updates through group links. Turning this off removes me from existing group links.',
          ),
          onChanged: _busy
              ? null
              : (value) => _run(() async {
                  await context.read<ApiClient>().patch(
                    '/guardian/consent/${Uri.encodeComponent(widget.groupId)}',
                    {'allowed': value},
                  );
                  if (mounted) _groupConsent = value;
                }),
        ),
        if (context.watch<ConvoyService?>()?.canEditRoute == true)
          Wrap(
            spacing: Space.s8,
            children: [
              for (final scope in const {
                'PERSONAL': 'My ride',
                'GROUP': 'Consenting group riders',
              }.entries)
                ChoiceChip(
                  label: Text(scope.value),
                  selected: _subject == scope.key,
                  onSelected: _busy
                      ? null
                      : (_) => setState(() {
                          _subject = scope.key;
                          _acknowledged = false;
                        }),
                ),
            ],
          ),
        const SizedBox(height: Space.s16),
        for (final option in const {
          'BASIC': 'Basic — status without exact location',
          'LIVE': 'Live — your last reported location',
          'EMERGENCY_ONLY':
              'Emergency only — incident location when help is requested',
        }.entries)
          RadioListTile<String>(
            value: option.key,
            groupValue: _level,
            title: Text(option.value),
            onChanged: _busy
                ? null
                : (v) => setState(() {
                    _level = v!;
                    _acknowledged = false;
                  }),
          ),
        const Text(
          'Expires within 72 hours, or 6 hours after the ride ends, whichever comes first. Live updates work while the page is open. Browser alerts require support, server configuration and the guardian’s permission.',
        ),
        TextField(
          controller: _pin,
          enabled: !_busy,
          obscureText: true,
          maxLength: 8,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
            labelText: 'Optional PIN',
            helperText: '4 to 8 digits. Send it separately from the link.',
          ),
        ),
        CheckboxListTile(
          value: _acknowledged,
          controlAffinity: ListTileControlAffinity.leading,
          title: const Text(
            'Anyone with this link can view the selected information until it expires or I revoke it.',
          ),
          onChanged: _busy
              ? null
              : (v) => setState(() => _acknowledged = v == true),
        ),
        FilledButton(
          onPressed: _busy || !_acknowledged ? null : _create,
          child: const Text('Create Guardian link'),
        ),
        if (_url != null) ...[
          const SizedBox(height: Space.s8),
          const Text(
            'Share now. For privacy, the original link cannot be recovered after this sheet closes.',
          ),
          OutlinedButton(
            onPressed: _busy
                ? null
                : () => _run(() async {
                    final box = context.findRenderObject() as RenderBox?;
                    await Share.share(
                      _url!,
                      sharePositionOrigin: box == null
                          ? null
                          : box.localToGlobal(Offset.zero) & box.size,
                    );
                  }),
            child: const Text('Share link'),
          ),
        ],
        if (_busy) const LinearProgressIndicator(),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: Space.s8),
            child: Text(_error!, semanticsLabel: 'Error: $_error'),
          ),
        const SizedBox(height: Space.s16),
        const Text('Your links'),
        for (final link in _links)
          ListTile(
            title: Text(
              '${link['subject']} · ${link['level']} · ${link['status']}',
            ),
            subtitle: const Text('An invitation, not a verified person.'),
            trailing: link['status'] == 'REVOKED'
                ? null
                : PopupMenuButton<String>(
                    enabled: !_busy,
                    onSelected: (action) {
                      if (action == 'revoke') {
                        _revoke(link['grantId'].toString());
                        return;
                      }
                      _run(() async {
                        final paused = link['status'] != 'PAUSED';
                        await context.read<ApiClient>().patch(
                          '/guardian/links/${Uri.encodeComponent(link['grantId'].toString())}',
                          {'paused': paused},
                        );
                        if (mounted) {
                          link['status'] = paused ? 'PAUSED' : 'ACTIVE';
                        }
                      });
                    },
                    itemBuilder: (_) => [
                      PopupMenuItem(
                        value: 'pause',
                        child: Text(
                          link['status'] == 'PAUSED'
                              ? 'Resume access'
                              : 'Pause access',
                        ),
                      ),
                      const PopupMenuItem(
                        value: 'revoke',
                        child: Text('Revoke link'),
                      ),
                    ],
                  ),
          ),
        TextButton(
          onPressed: _busy ? null : _load,
          child: const Text('Refresh links'),
        ),
      ],
    ),
  );
}
