/// v3.63 trip planning lite: the pre-ride checklist (pure Dart; stored on the phone per rider).
///
/// Never blocks starting or joining a ride and never shows while riding. "All good" ticks everything at once.
library;

/// One item: a stable [id], its words, and its group for the screen.
class ChecklistItem {
  const ChecklistItem(this.id, this.label, this.group, {this.custom = false});
  final String id;
  final String label;
  final String group;
  final bool custom;

  Map<String, Object> toJson() => {'id': id, 'label': label, 'group': group, 'custom': custom};
  static ChecklistItem? fromJson(Object? j) {
    if (j is! Map || j['id'] is! String || j['label'] is! String) return null;
    return ChecklistItem(j['id'] as String, j['label'] as String, (j['group'] as String?) ?? 'Mine', custom: j['custom'] == true);
  }
}

/// Groups in screen order.
const List<String> checklistGroups = ['Documents', 'Bike', 'You', 'Phone and safety', 'Mine'];

/// The default list (owner: documents, tyres, fuel ...). Items linked to app settings carry these ids:
/// 'contacts' (emergency contacts set), 'medical' (Medical ID set), 'offline_map' (map of the route saved).
const List<ChecklistItem> defaultChecklist = [
  ChecklistItem('licence', 'Driving licence', 'Documents'),
  ChecklistItem('rc', 'RC (registration)', 'Documents'),
  ChecklistItem('insurance', 'Insurance', 'Documents'),
  ChecklistItem('puc', 'PUC certificate', 'Documents'),
  ChecklistItem('tyres', 'Tyres and pressure', 'Bike'),
  ChecklistItem('chain', 'Chain cleaned and oiled', 'Bike'),
  ChecklistItem('brakes', 'Brakes', 'Bike'),
  ChecklistItem('lights', 'Lights and indicators', 'Bike'),
  ChecklistItem('fuel', 'Fuel for the first stretch', 'Bike'),
  ChecklistItem('helmet', 'Helmet and riding gear', 'You'),
  ChecklistItem('phone', 'Phone charged (and a power bank)', 'Phone and safety'),
  ChecklistItem('contacts', 'Emergency contacts set', 'Phone and safety'),
  ChecklistItem('medical', 'Medical ID set', 'Phone and safety'),
  ChecklistItem('offline_map', 'Offline map of the route saved', 'Phone and safety'),
];

/// The rider's list and ticks.
class PreRideChecklist {
  PreRideChecklist({List<ChecklistItem>? items, Set<String>? done, Set<String>? hidden})
      : items = items ?? [...defaultChecklist],
        done = done ?? <String>{},
        hidden = hidden ?? <String>{};

  final List<ChecklistItem> items;
  final Set<String> done;

  /// Default items the rider removed.
  final Set<String> hidden;

  List<ChecklistItem> get visible => [for (final i in items) if (!hidden.contains(i.id)) i];
  int get doneCount => visible.where((i) => done.contains(i.id)).length;
  int get total => visible.length;
  bool get allDone => total > 0 && doneCount == total;

  void toggle(String id) => done.contains(id) ? done.remove(id) : done.add(id);
  void allGood() => done.addAll(visible.map((i) => i.id));
  void reset() => done.clear();

  /// Adds the rider's own item (1-50 characters); returns false when empty or already there.
  bool addCustom(String label) {
    final l = label.replaceAll(RegExp(r'[\u0000-\u001f]'), '').trim();
    if (l.isEmpty || l.length > 50) return false;
    if (items.any((i) => i.label.toLowerCase() == l.toLowerCase())) return false;
    var n = 1;
    while (items.any((i) => i.id == 'mine_$n')) {
      n++;
    }
    items.add(ChecklistItem('mine_$n', l, 'Mine', custom: true));
    return true;
  }

  /// Own items are deleted; default items are hidden (and can be brought back with [restoreDefaults]).
  void remove(String id) {
    final i = items.indexWhere((x) => x.id == id);
    if (i < 0) return;
    if (items[i].custom) {
      items.removeAt(i);
    } else {
      hidden.add(id);
    }
    done.remove(id);
  }

  void restoreDefaults() => hidden.clear();

  /// Ticks are for one ride: older than [maxAge] they start fresh (the list itself stays).
  static const Duration maxAge = Duration(hours: 18);

  Map<String, Object> toJson(int nowMs) => {
        'v': 1,
        'at': nowMs,
        'custom': [for (final i in items) if (i.custom) i.toJson()],
        'hidden': hidden.toList(),
        'done': done.toList(),
      };

  static PreRideChecklist fromJson(Object? j, {required int nowMs}) {
    if (j is! Map) return PreRideChecklist();
    final items = [...defaultChecklist];
    final custom = j['custom'];
    if (custom is List) {
      for (final c in custom.take(30)) {
        final i = ChecklistItem.fromJson(c);
        if (i != null && i.custom && !items.any((x) => x.id == i.id)) items.add(i);
      }
    }
    final at = (j['at'] as num?)?.toInt() ?? 0;
    final fresh = nowMs - at <= maxAge.inMilliseconds;
    return PreRideChecklist(
      items: items,
      hidden: {for (final h in (j['hidden'] is List ? j['hidden'] as List : const [])) if (h is String) h},
      done: fresh ? {for (final d in (j['done'] is List ? j['done'] as List : const [])) if (d is String) d} : <String>{},
    );
  }
}
