import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_theme.dart';
import '../../core/ui/ui.dart';
import '../../data/services/crews_service.dart';
import '../../data/services/friends_service.dart';
import '../../domain/social/crew_rules.dart';
import 'user_avatar.dart';

/// One friend in a [FriendPickerList].
class PickableFriend {
  final String username;
  final String? avatarUrl;

  /// Null = pickable; otherwise why not ("In the crew", "Invited").
  final String? lockedReason;
  const PickableFriend({required this.username, this.avatarUrl, this.lockedReason});
  bool get pickable => lockedReason == null;
}

/// Friends to tick, with a search box and "Select all" (crew creation, crew invites).
class FriendPickerList extends StatefulWidget {
  final List<PickableFriend> friends;
  final Set<String> picked;
  final ValueChanged<Set<String>> onChanged;

  /// Most friends that can be picked at once (crew size).
  final int? cap;
  const FriendPickerList({super.key, required this.friends, required this.picked, required this.onChanged, this.cap});

  @override
  State<FriendPickerList> createState() => _FriendPickerListState();
}

class _FriendPickerListState extends State<FriendPickerList> {
  final _filter = TextEditingController();

  @override
  void dispose() {
    _filter.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final byName = {for (final f in widget.friends) f.username: f};
    final visible = filterUsernames(widget.friends.map((f) => f.username), _filter.text);
    final pickable = visible.where((u) => byName[u]!.pickable).toList();
    final allPicked = pickable.isNotEmpty && pickable.every(widget.picked.contains);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.friends.length > 6)
          Padding(
            padding: const EdgeInsets.only(bottom: Space.s8),
            child: TextField(
              controller: _filter,
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(prefixIcon: Icon(Icons.search_rounded), hintText: 'Search friends'),
              onChanged: (_) => setState(() {}),
            ),
          ),
        if (pickable.length > 1)
          CheckboxListTile(
            key: const Key('picker_select_all'),
            value: allPicked,
            contentPadding: EdgeInsets.zero,
            title: Text('Select all', style: AppText.body.copyWith(fontWeight: FontWeight.w600)),
            onChanged: (_) => widget.onChanged(toggleAllPicked(widget.picked, pickable, cap: widget.cap)),
          ),
        Flexible(
          child: ListView(
            shrinkWrap: true,
            children: [
              for (final u in visible)
                CheckboxListTile(
                  value: byName[u]!.pickable ? widget.picked.contains(u) : true,
                  contentPadding: EdgeInsets.zero,
                  onChanged: byName[u]!.pickable
                      ? (v) {
                          final next = {...widget.picked};
                          if (v == true) {
                            if (widget.cap != null && next.length >= widget.cap!) return;
                            next.add(u);
                          } else {
                            next.remove(u);
                          }
                          widget.onChanged(next);
                        }
                      : null,
                  secondary: UserAvatar(label: u, avatarUrl: byName[u]!.avatarUrl, size: 36),
                  title: Text(u, maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: byName[u]!.lockedReason == null ? null : Text(byName[u]!.lockedReason!),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// "Create crew" in two steps: a name, then friends to invite (search, select all). Returns the
/// new crewId (the caller opens the crew), or null when closed.
class CreateCrewFlow extends StatefulWidget {
  const CreateCrewFlow({super.key});

  static Future<String?> open(BuildContext context) => showAppSheet<String>(
        context,
        title: 'Create crew',
        isScrollControlled: true,
        builder: (_) => const CreateCrewFlow(),
      );

  @override
  State<CreateCrewFlow> createState() => _CreateCrewFlowState();
}

class _CreateCrewFlowState extends State<CreateCrewFlow> {
  final _name = TextEditingController();
  int _step = 0;
  Set<String> _picked = {};
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _next() {
    final err = CrewRules.checkName(_name.text);
    if (err != null) return setState(() => _error = err);
    setState(() {
      _error = null;
      _step = 1;
    });
  }

  Future<void> _create() async {
    final crews = context.read<CrewsService>();
    setState(() {
      _busy = true;
      _error = null;
    });
    final (crewId, err) = await crews.create(_name.text, '');
    if (!mounted) return;
    if (err != null || crewId == null) {
      setState(() {
        _busy = false;
        _error = err ?? 'Could not create the crew. Try again.';
      });
      return;
    }
    if (_picked.isNotEmpty) await crews.invite(crewId, _picked.toList());
    if (mounted) Navigator.pop(context, crewId);
  }

  @override
  Widget build(BuildContext context) {
    final friends = context.watch<FriendsService?>()?.friends ?? const <FriendEntry>[];
    return Padding(
      padding: EdgeInsets.only(bottom: 16 + MediaQuery.viewInsetsOf(context).bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(_step == 0 ? 'Step 1 of 2 · Name' : 'Step 2 of 2 · Invite friends', style: AppText.caption.copyWith(color: AppTheme.text2)),
          const SizedBox(height: Space.s12),
          if (_step == 0) ...[
            TextField(
              key: const Key('crew_name_field'),
              controller: _name,
              autofocus: true,
              maxLength: CrewLimits.nameMax,
              textCapitalization: TextCapitalization.words,
              textInputAction: TextInputAction.next,
              decoration: InputDecoration(labelText: 'Crew name', errorText: _error),
              onSubmitted: (_) => _next(),
            ),
            const SizedBox(height: Space.s8),
            DsButton(label: 'Next', onPressed: _next),
          ] else ...[
            if (friends.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: Space.s12),
                child: Text('No friends yet. You can invite them later.', style: AppText.body.copyWith(color: AppTheme.text2)),
              )
            else
              ConstrainedBox(
                constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.45),
                child: FriendPickerList(
                  friends: [for (final f in friends) PickableFriend(username: f.username, avatarUrl: f.avatarUrl)],
                  picked: _picked,
                  cap: CrewLimits.maxMembers - 1,
                  onChanged: (s) => setState(() => _picked = s),
                ),
              ),
            if (_error != null) ...[
              const SizedBox(height: Space.s8),
              Text(_error!, style: AppText.body.copyWith(color: AppTheme.sos)),
            ],
            const SizedBox(height: Space.s12),
            DsButton(
              key: const Key('crew_create_button'),
              label: _busy ? 'Creating...' : (_picked.isEmpty ? 'Create crew' : 'Create and invite ${_picked.length}'),
              onPressed: _busy ? null : _create,
            ),
            TextButton(onPressed: _busy ? null : () => setState(() => _step = 0), child: const Text('Back')),
          ],
        ],
      ),
    );
  }
}
