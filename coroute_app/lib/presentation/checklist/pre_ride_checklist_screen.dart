import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/theme/app_theme.dart';
import '../../core/ui/ui.dart';
import '../../domain/expenses/pre_ride_checklist.dart';
import '../home/ride_start_view.dart' show RideStartView;

/// v3.63 trip planning lite: the pre-ride checklist (documents, bike, gear, phone and safety).
///
/// Optional and never in the way: opened from Plan a ride and the start sheet, never while riding, never blocks a
/// start. Ticks are kept on the phone for one ride (18 h); the rider's own items and removed defaults stay.
/// [openSafetySetup] opens the emergency contacts / Medical ID screen when the rider taps those items' link.
class PreRideChecklistScreen extends StatefulWidget {
  const PreRideChecklistScreen({super.key, this.openSafetySetup, this.userKey = ''});

  final VoidCallback? openSafetySetup;

  /// Per rider on a shared phone (the signed-in user id); '' = this phone.
  final String userKey;

  static Future<void> open(BuildContext context, {VoidCallback? openSafetySetup, String userKey = ''}) {
    return Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => PreRideChecklistScreen(openSafetySetup: openSafetySetup, userKey: userKey)));
  }

  @override
  State<PreRideChecklistScreen> createState() => _PreRideChecklistScreenState();
}

class ChecklistStore {
  static String keyFor(String userKey) => 'pre_ride_checklist_v1${userKey.isEmpty ? '' : '_$userKey'}';

  static Future<PreRideChecklist> load(String userKey) async {
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString(keyFor(userKey));
      return PreRideChecklist.fromJson(raw == null ? null : jsonDecode(raw), nowMs: DateTime.now().millisecondsSinceEpoch);
    } catch (_) {
      return PreRideChecklist();
    }
  }

  static Future<void> save(String userKey, PreRideChecklist c) async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(keyFor(userKey), jsonEncode(c.toJson(DateTime.now().millisecondsSinceEpoch)));
    } catch (_) {/* best effort */}
  }
}

class _PreRideChecklistScreenState extends State<PreRideChecklistScreen> {
  PreRideChecklist? _list;
  bool _editing = false;
  final TextEditingController _add = TextEditingController();

  @override
  void initState() {
    super.initState();
    ChecklistStore.load(widget.userKey).then((c) {
      if (mounted) setState(() => _list = c);
    });
  }

  @override
  void dispose() {
    _add.dispose();
    super.dispose();
  }

  void _change(void Function(PreRideChecklist c) fn) {
    final c = _list;
    if (c == null) return;
    setState(() => fn(c));
    ChecklistStore.save(widget.userKey, c);
  }

  @override
  Widget build(BuildContext context) {
    final c = _list;
    return Scaffold(
      backgroundColor: AppTheme.bg,
      appBar: AppBar(
        title: const Text('Before you ride'),
        actions: [
          TextButton(key: const Key('checklist_edit'), onPressed: () => setState(() => _editing = !_editing), child: Text(_editing ? 'Done' : 'Edit list')),
        ],
      ),
      body: c == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
              children: [
                DsCard(
                  child: Row(children: [
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(c.allDone ? 'All set. Ride safe.' : '${c.doneCount} of ${c.total} checked', style: AppText.title.copyWith(fontSize: 17)),
                        const SizedBox(height: 4),
                        Text('Optional: it never stops you from starting a ride.', style: AppText.caption),
                      ]),
                    ),
                    if (!c.allDone)
                      FilledButton(
                        key: const Key('checklist_all_good'),
                        onPressed: () {
                          HapticFeedback.selectionClick();
                          _change((x) => x.allGood());
                        },
                        child: const Text('All good'),
                      )
                    else
                      TextButton(onPressed: () => _change((x) => x.reset()), child: const Text('Start over')),
                  ]),
                ),
                const SizedBox(height: 8),
                for (final g in checklistGroups) ..._group(c, g),
                if (_editing) ...[
                  const SizedBox(height: 12),
                  Row(children: [
                    Expanded(
                      child: TextField(
                        key: const Key('checklist_add_field'),
                        controller: _add,
                        maxLength: 50,
                        decoration: const InputDecoration(labelText: 'Add your own item', counterText: ''),
                        onSubmitted: (_) => _addItem(),
                      ),
                    ),
                    IconButton(tooltip: 'Add', constraints: const BoxConstraints(minWidth: 48, minHeight: 48), onPressed: _addItem, icon: const Icon(Icons.add_circle_outline_rounded)),
                  ]),
                  if (c.hidden.isNotEmpty)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton(onPressed: () => _change((x) => x.restoreDefaults()), child: const Text('Bring back removed items')),
                    ),
                ],
              ],
            ),
    );
  }

  void _addItem() {
    final t = _add.text;
    var ok = false;
    _change((x) => ok = x.addCustom(t));
    if (ok) _add.clear();
  }

  List<Widget> _group(PreRideChecklist c, String group) {
    final items = [for (final i in c.visible) if (i.group == group) i];
    if (items.isEmpty) return const [];
    return [
      const SizedBox(height: 12),
      DsSectionHeader(group),
      const SizedBox(height: 4),
      DsCard(
        padding: EdgeInsets.zero,
        child: Column(children: [
          for (final i in items)
            CheckboxListTile(
              key: Key('checklist_${i.id}'),
              value: c.done.contains(i.id),
              onChanged: _editing ? null : (_) => _change((x) => x.toggle(i.id)),
              controlAffinity: ListTileControlAffinity.leading,
              title: Text(i.label, style: AppText.body),
              secondary: _editing
                  ? IconButton(
                      tooltip: 'Remove',
                      constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                      onPressed: () => _change((x) => x.remove(i.id)),
                      icon: Icon(Icons.remove_circle_outline_rounded, color: AppTheme.textMuted),
                    )
                  : ((i.id == 'contacts' || i.id == 'medical')
                      ? TextButton(onPressed: widget.openSafetySetup ?? () => RideStartView.openProfile(context), child: const Text('Set'))
                      : null),
            ),
        ]),
      ),
    ];
  }
}
