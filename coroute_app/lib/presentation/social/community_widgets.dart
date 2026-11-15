import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_theme.dart';
import '../../core/ui/ui.dart';
import '../../data/services/api_client.dart';
import '../../data/services/avatar_image_codec.dart';
import '../../data/services/communities_service.dart';
import '../../data/services/crews_service.dart';
import '../../domain/media/avatar_crop.dart';
import 'crew_detail_screen.dart';
import 'rider_profile_screen.dart';
import 'user_avatar.dart';

/// v3.60 communities: shared widgets (picture, public / private chip, hosted rides, join requests) and the
/// "Find communities" screens.
CommunitiesService communitiesOf(BuildContext context) => CommunitiesService(context.read<ApiClient>());

/// The community picture (rounded square), or its first letter.
class CommunityAvatar extends StatelessWidget {
  final String name;
  final String? photoUrl;
  final double size;
  const CommunityAvatar({super.key, required this.name, this.photoUrl, this.size = 48});

  @override
  Widget build(BuildContext context) {
    if (photoUrl != null) {
      return ClipRRect(borderRadius: BorderRadius.circular(size * 0.28), child: UserAvatar(label: name, avatarUrl: photoUrl, size: size));
    }
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: AppTheme.tint, borderRadius: BorderRadius.circular(size * 0.28)),
      child: Text(name.isEmpty ? '?' : name.characters.first.toUpperCase(), style: AppText.title.copyWith(color: AppTheme.accentText, fontSize: size * 0.42)),
    );
  }
}

class VisibilityChip extends StatelessWidget {
  final bool isPublic;
  const VisibilityChip({super.key, required this.isPublic});

  @override
  Widget build(BuildContext context) => InfoPill(
        icon: isPublic ? Icons.public_rounded : Icons.lock_outline_rounded,
        text: isPublic ? 'Public' : 'Private',
        color: AppTheme.accentText,
        background: AppTheme.tint,
      );
}

/// Picks a picture, cuts the centre square on the phone (no metadata) and uploads it. Returns an error or null.
Future<String?> pickCommunityPhoto(BuildContext context, String crewId) async {
  final svc = communitiesOf(context);
  try {
    final f = await ImagePicker().pickImage(source: ImageSource.gallery, maxWidth: 2048, maxHeight: 2048, imageQuality: 90, requestFullMetadata: false);
    if (f == null) return null;
    final image = await AvatarImageCodec.decode(await f.readAsBytes());
    try {
      final pic = await AvatarImageCodec.renderCrop(image, AvatarCrop.initial);
      return await svc.setPhoto(crewId, pic.bytes, pic.mime);
    } finally {
      image.dispose();
    }
  } catch (_) {
    return 'Could not open your photos.';
  }
}

// ---------------------------------------------------------------- hosted rides

/// The community's planned rides: Interested / Not interested for members; admins plan, edit and cancel.
class CommunityRidesSection extends StatefulWidget {
  final String crewId;
  final bool member;
  const CommunityRidesSection({super.key, required this.crewId, this.member = true});

  @override
  State<CommunityRidesSection> createState() => _CommunityRidesSectionState();
}

class _CommunityRidesSectionState extends State<CommunityRidesSection> {
  List<CommunityRide>? _rides;
  bool _canHost = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    try {
      final (list, canHost) = await communitiesOf(context).rides(widget.crewId);
      if (mounted) {
        setState(() {
          _rides = list;
          _canHost = canHost;
          _error = null;
        });
      }
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.statusCode == 403 ? null : e.message);
      if (mounted && e.statusCode == 403) setState(() => _rides = const []);
    } catch (_) {
      if (mounted) setState(() => _error = 'Could not load the rides.');
    }
  }

  Future<void> _plan([CommunityRide? edit]) async {
    final done = await showAppSheet<bool>(
      context,
      title: edit == null ? 'Plan a ride' : 'Edit ride',
      isScrollControlled: true,
      builder: (_) => _PlanRideForm(crewId: widget.crewId, edit: edit),
    );
    if (done == true) await _load();
  }

  Future<void> _answer(CommunityRide r, bool interested) async {
    AppHaptics.selection();
    final err = await communitiesOf(context).answer(widget.crewId, r.rideId, interested);
    if (!mounted) return;
    if (err != null) showAppToast(context, err, error: true);
    await _load();
  }

  Future<void> _menu(CommunityRide r) async {
    final choice = await showAppSheet<String>(
      context,
      title: r.title,
      builder: (ctx) => Column(mainAxisSize: MainAxisSize.min, children: [
        DsListRow(icon: Icons.edit_outlined, label: 'Edit ride', onTap: () => Navigator.pop(ctx, 'edit')),
        DsListRow(icon: Icons.event_busy_rounded, label: 'Cancel ride', divider: false, onTap: () => Navigator.pop(ctx, 'cancel')),
      ]),
    );
    if (!mounted || choice == null) return;
    if (choice == 'edit') return _plan(r);
    final ok = await confirmAction(context, title: 'Cancel ${r.title}?', message: 'Members are told the ride is off.', confirmLabel: 'Cancel ride', destructive: true);
    if (!ok || !mounted) return;
    final err = await communitiesOf(context).cancelRide(widget.crewId, r.rideId);
    if (mounted && err != null) showAppToast(context, err, error: true);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final rides = _rides;
    final upcoming = (rides ?? const <CommunityRide>[]).where((r) => !r.past).toList();
    final past = (rides ?? const <CommunityRide>[]).where((r) => r.past).toList();
    return Column(
      key: const Key('community_rides'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_canHost) ...[
          DsButton(key: const Key('community_plan_ride'), label: 'Plan a ride', icon: Icons.event_rounded, tone: DsButtonTone.outline, onPressed: () => _plan()),
          const SizedBox(height: Space.s12),
        ],
        if (_error != null)
          Text(_error!, style: AppText.label.copyWith(color: AppTheme.warnText))
        else if (rides == null)
          const SkeletonRows(count: 2)
        else if (upcoming.isEmpty && past.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(_canHost ? 'No rides planned. Plan one and members say if they are in.' : 'No rides planned yet.', textAlign: TextAlign.center, style: AppText.body.copyWith(color: AppTheme.text2)),
          ),
        for (final r in upcoming) _RideCard(ride: r, member: widget.member, onAnswer: (v) => _answer(r, v), onMenu: r.canEdit && !r.cancelled ? () => _menu(r) : null),
        if (past.isNotEmpty) ...[
          const SizedBox(height: Space.s8),
          Text('Earlier', style: AppText.label.copyWith(color: AppTheme.text2)),
          const SizedBox(height: Space.s8),
          for (final r in past) _RideCard(ride: r, member: false, onAnswer: null, onMenu: null),
        ],
      ],
    );
  }
}

class _RideCard extends StatelessWidget {
  final CommunityRide ride;
  final bool member;
  final ValueChanged<bool>? onAnswer;
  final VoidCallback? onMenu;
  const _RideCard({required this.ride, required this.member, required this.onAnswer, required this.onMenu});

  @override
  Widget build(BuildContext context) {
    final r = ride;
    final route = [r.meetName, if (r.destName.isNotEmpty) r.destName].join(' to ');
    return Padding(
      padding: const EdgeInsets.only(bottom: Space.s12),
      child: DsCard(
        key: Key('community_ride_${r.rideId}'),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(children: [
              Expanded(
                child: Text(r.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: AppText.title.copyWith(decoration: r.cancelled ? TextDecoration.lineThrough : null)),
              ),
              if (onMenu != null) IconButton(tooltip: 'Ride options', constraints: const BoxConstraints(minWidth: 48, minHeight: 48), onPressed: onMenu, icon: const Icon(Icons.more_vert_rounded)),
            ]),
            const SizedBox(height: 4),
            Row(children: [
              Icon(Icons.schedule_rounded, size: 16, color: AppTheme.text2),
              const SizedBox(width: 6),
              Expanded(child: Text(r.cancelled ? 'Cancelled' : r.when, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.label)),
            ]),
            const SizedBox(height: 2),
            Row(children: [
              Icon(Icons.place_outlined, size: 16, color: AppTheme.text2),
              const SizedBox(width: 6),
              Expanded(child: Text(route, maxLines: 2, overflow: TextOverflow.ellipsis, style: AppText.label)),
            ]),
            if (r.notes.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(r.notes, style: AppText.body.copyWith(color: AppTheme.text2)),
            ],
            const SizedBox(height: 8),
            Text(
              '${r.interestedCount} interested${r.host != null ? ' · hosted by ${r.host!.username}' : ''}',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: AppText.caption,
            ),
            if (member && onAnswer != null && !r.cancelled) ...[
              const SizedBox(height: 10),
              Row(children: [
                Expanded(
                  child: _AnswerButton(
                    key: Key('ride_interested_${r.rideId}'),
                    label: 'Interested',
                    icon: Icons.thumb_up_alt_outlined,
                    selected: r.myAnswer == 'INTERESTED',
                    onTap: () => onAnswer!(true),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _AnswerButton(
                    key: Key('ride_not_interested_${r.rideId}'),
                    label: 'Not interested',
                    icon: Icons.thumb_down_alt_outlined,
                    selected: r.myAnswer == 'NOT_INTERESTED',
                    onTap: () => onAnswer!(false),
                  ),
                ),
              ]),
            ],
          ],
        ),
      ),
    );
  }
}

class _AnswerButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;
  const _AnswerButton({super.key, required this.label, required this.icon, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) => Semantics(
        selected: selected,
        button: true,
        child: OutlinedButton.icon(
          style: OutlinedButton.styleFrom(
            minimumSize: const Size.fromHeight(48),
            backgroundColor: selected ? AppTheme.tint : null,
            foregroundColor: selected ? AppTheme.accentText : AppTheme.text,
            side: BorderSide(color: selected ? AppTheme.brand : AppTheme.border, width: selected ? 2 : 1),
          ),
          onPressed: onTap,
          icon: Icon(icon, size: 18),
          label: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
      );
}

class _PlanRideForm extends StatefulWidget {
  final String crewId;
  final CommunityRide? edit;
  const _PlanRideForm({required this.crewId, this.edit});

  @override
  State<_PlanRideForm> createState() => _PlanRideFormState();
}

class _PlanRideFormState extends State<_PlanRideForm> {
  late final _title = TextEditingController(text: widget.edit?.title ?? '');
  late final _meet = TextEditingController(text: widget.edit?.meetName ?? '');
  late final _dest = TextEditingController(text: widget.edit?.destName ?? '');
  late final _notes = TextEditingController(text: widget.edit?.notes ?? '');
  late DateTime _at = widget.edit != null ? DateTime.fromMillisecondsSinceEpoch(widget.edit!.startAt) : DateTime.now().add(const Duration(days: 1)).copyWith(hour: 6, minute: 0, second: 0, millisecond: 0, microsecond: 0);
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    for (final c in [_title, _meet, _dest, _notes]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _pickTime() async {
    final d = await showDatePicker(context: context, initialDate: _at, firstDate: DateTime.now(), lastDate: DateTime.now().add(const Duration(days: 180)));
    if (d == null || !mounted) return;
    final t = await showTimePicker(context: context, initialTime: TimeOfDay.fromDateTime(_at));
    if (t == null) return;
    setState(() => _at = DateTime(d.year, d.month, d.day, t.hour, t.minute));
  }

  Future<void> _save() async {
    if (_title.text.trim().isEmpty || _meet.text.trim().isEmpty) return setState(() => _error = 'Add a title and a meeting place.');
    setState(() {
      _busy = true;
      _error = null;
    });
    final svc = communitiesOf(context);
    final e = widget.edit;
    final err = e == null
        ? await svc.createRide(widget.crewId, title: _title.text, meetName: _meet.text, destName: _dest.text, notes: _notes.text, startAt: _at)
        : await svc.updateRide(widget.crewId, e.rideId, title: _title.text, meetName: _meet.text, destName: _dest.text, notes: _notes.text, startAt: _at);
    if (!mounted) return;
    setState(() => _busy = false);
    if (err != null) return setState(() => _error = err);
    Navigator.pop(context, true);
  }

  static String _label(DateTime d) {
    const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    const mo = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    final h = d.hour % 12 == 0 ? 12 : d.hour % 12;
    return '${days[d.weekday - 1]} ${d.day} ${mo[d.month - 1]}, $h:${d.minute.toString().padLeft(2, '0')} ${d.hour < 12 ? 'am' : 'pm'}';
  }

  @override
  Widget build(BuildContext context) => Padding(
        padding: EdgeInsets.only(bottom: 16 + MediaQuery.viewInsetsOf(context).bottom),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(key: const Key('ride_title'), controller: _title, maxLength: 60, decoration: const InputDecoration(labelText: 'Ride name', hintText: 'Sunrise run to Nandi Hills')),
            TextField(key: const Key('ride_meet'), controller: _meet, maxLength: 80, decoration: const InputDecoration(labelText: 'Meeting place')),
            TextField(key: const Key('ride_dest'), controller: _dest, maxLength: 80, decoration: const InputDecoration(labelText: 'Destination (optional)')),
            DsListRow(key: const Key('ride_when'), icon: Icons.schedule_rounded, label: 'Start', value: _label(_at), divider: false, onTap: _pickTime),
            TextField(key: const Key('ride_notes'), controller: _notes, maxLength: 300, minLines: 1, maxLines: 3, decoration: const InputDecoration(labelText: 'Notes (optional)', hintText: 'Full tank, rain gear')),
            if (_error != null) Padding(padding: const EdgeInsets.only(bottom: 8), child: Text(_error!, style: AppText.label.copyWith(color: AppTheme.warnText))),
            DsButton(key: const Key('ride_save'), label: _busy ? 'Saving…' : (widget.edit == null ? 'Plan ride' : 'Save'), onPressed: _busy ? null : _save),
            const SizedBox(height: 6),
            Text('Members get a notice and say Interested or Not interested. At ride time, start the ride and invite them from Rides.', style: AppText.caption, textAlign: TextAlign.center),
          ],
        ),
      );
}

// ---------------------------------------------------------------- join requests (admins)

class JoinRequestsScreen extends StatefulWidget {
  final String crewId;
  final String name;
  const JoinRequestsScreen({super.key, required this.crewId, required this.name});

  static Future<void> open(BuildContext context, String crewId, String name) =>
      Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => JoinRequestsScreen(crewId: crewId, name: name)));

  @override
  State<JoinRequestsScreen> createState() => _JoinRequestsScreenState();
}

class _JoinRequestsScreenState extends State<JoinRequestsScreen> {
  List<(RiderCard, int)>? _list;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    try {
      final l = await communitiesOf(context).requests(widget.crewId);
      if (mounted) setState(() => _list = l);
    } catch (_) {
      if (mounted) setState(() => _error = 'Could not load the requests.');
    }
  }

  Future<void> _decide(RiderCard r, bool approve) async {
    final err = await communitiesOf(context).decide(widget.crewId, r.username, approve);
    if (!mounted) return;
    showAppToast(context, err ?? (approve ? '${r.username} is in' : 'Request declined'), error: err != null);
    context.read<CrewsService?>()?.refresh().ignore();
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final list = _list;
    return Scaffold(
      appBar: AppBar(title: Text('Join requests · ${widget.name}', maxLines: 1, overflow: TextOverflow.ellipsis)),
      body: list == null
          ? (_error != null ? ErrorState(title: _error!, onRetry: _load) : const Padding(padding: EdgeInsets.all(20), child: SkeletonRows(count: 3)))
          : list.isEmpty
              ? const EmptyState(icon: Icons.how_to_reg_outlined, title: 'No requests', message: 'Riders who ask to join show here.')
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
                  itemCount: list.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (_, i) {
                    final r = list[i].$1;
                    return DsCard(
                      key: Key('join_request_${r.username}'),
                      child: Row(children: [
                        InkWell(onTap: () => RiderProfileScreen.open(context, r.username), child: UserAvatar(label: r.username, avatarUrl: r.avatarUrl, size: 44)),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text(r.username, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.title.copyWith(fontSize: 15)),
                            if (r.displayName.isNotEmpty) Text(r.displayName, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.label),
                          ]),
                        ),
                        TextButton(key: Key('decline_${r.username}'), style: TextButton.styleFrom(minimumSize: const Size(56, 48)), onPressed: () => _decide(r, false), child: const Text('Decline')),
                        FilledButton(key: Key('approve_${r.username}'), style: FilledButton.styleFrom(minimumSize: const Size(64, 48)), onPressed: () => _decide(r, true), child: const Text('Add')),
                      ]),
                    );
                  },
                ),
    );
  }
}

// ---------------------------------------------------------------- find communities

class FindCommunitiesScreen extends StatefulWidget {
  const FindCommunitiesScreen({super.key});

  static Future<void> open(BuildContext context) => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const FindCommunitiesScreen()));

  @override
  State<FindCommunitiesScreen> createState() => _FindCommunitiesScreenState();
}

class _FindCommunitiesScreenState extends State<FindCommunitiesScreen> {
  final _q = TextEditingController();
  List<CommunitySummary>? _list;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _search());
  }

  @override
  void dispose() {
    _q.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    try {
      final l = await communitiesOf(context).discover(q: _q.text);
      if (mounted) {
        setState(() {
          _list = l;
          _error = null;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _error = 'Could not load communities.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final list = _list;
    return Scaffold(
      appBar: AppBar(title: const Text('Find communities')),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: TextField(
            key: const Key('communities_search'),
            controller: _q,
            textInputAction: TextInputAction.search,
            onSubmitted: (_) => _search(),
            decoration: InputDecoration(
              hintText: 'Search by name',
              prefixIcon: const Icon(Icons.search_rounded),
              suffixIcon: IconButton(tooltip: 'Search', onPressed: _search, icon: const Icon(Icons.arrow_forward_rounded)),
            ),
          ),
        ),
        Expanded(
          child: list == null
              ? (_error != null ? ErrorState(title: _error!, onRetry: _search) : const Padding(padding: EdgeInsets.all(16), child: SkeletonRows(count: 4)))
              : list.isEmpty
                  ? const EmptyState(icon: Icons.groups_outlined, title: 'No communities found', message: 'Try another name, or start your own community.')
                  : RefreshIndicator(
                      onRefresh: _search,
                      child: ListView.separated(
                        padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
                        itemCount: list.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 8),
                        itemBuilder: (_, i) => _CommunityRow(c: list[i], onChanged: _search),
                      ),
                    ),
        ),
      ]),
    );
  }
}

class _CommunityRow extends StatelessWidget {
  final CommunitySummary c;
  final VoidCallback onChanged;
  const _CommunityRow({required this.c, required this.onChanged});

  @override
  Widget build(BuildContext context) => DsCard(
        key: Key('community_${c.crewId}'),
        onTap: () async {
          if (c.status == 'MEMBER') {
            await CrewDetailScreen.open(context, c.crewId);
          } else {
            await CommunityPreviewScreen.open(context, c.crewId);
          }
          onChanged();
        },
        child: Row(children: [
          CommunityAvatar(name: c.name, photoUrl: c.photoUrl, size: 52),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(c.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.title),
              const SizedBox(height: 2),
              Text('${c.memberCount} ${c.memberCount == 1 ? 'member' : 'members'} · ${c.isPublic ? 'Public' : 'Private'}', maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.label),
            ]),
          ),
          const SizedBox(width: 8),
          DsChip(switch (c.status) { 'MEMBER' => 'Member', 'REQUESTED' => 'Requested', _ => c.isPublic ? 'Join' : 'Ask to join' }),
        ]),
      );
}

/// A community I am not in: public shows members and rides; private only the summary. Join / Ask to join.
class CommunityPreviewScreen extends StatefulWidget {
  final String crewId;
  const CommunityPreviewScreen({super.key, required this.crewId});

  static Future<void> open(BuildContext context, String crewId) =>
      Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => CommunityPreviewScreen(crewId: crewId)));

  @override
  State<CommunityPreviewScreen> createState() => _CommunityPreviewScreenState();
}

class _CommunityPreviewScreenState extends State<CommunityPreviewScreen> {
  CommunityView? _v;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    try {
      final v = await communitiesOf(context).view(widget.crewId);
      if (mounted) setState(() => _v = v);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.statusCode == 404 ? 'This community is not available.' : e.message);
    } catch (_) {
      if (mounted) setState(() => _error = 'Could not load the community.');
    }
  }

  Future<void> _join() async {
    setState(() => _busy = true);
    final svc = communitiesOf(context);
    final crews = context.read<CrewsService?>();
    final (status, err) = await svc.join(widget.crewId);
    if (!mounted) return;
    setState(() => _busy = false);
    if (err != null) return showAppToast(context, err, error: true);
    crews?.refresh().ignore();
    if (status == 'MEMBER') {
      showAppToast(context, 'Welcome in');
      await Navigator.of(context).pushReplacement(MaterialPageRoute<void>(builder: (_) => CrewDetailScreen(crewId: widget.crewId)));
      return;
    }
    showAppToast(context, 'Request sent. An admin will let you in.');
    await _load();
  }

  Future<void> _cancel() async {
    final err = await communitiesOf(context).cancelRequest(widget.crewId);
    if (!mounted) return;
    if (err != null) showAppToast(context, err, error: true);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final v = _v;
    final c = v?.summary;
    return Scaffold(
      appBar: AppBar(title: Text(c?.name ?? 'Community', maxLines: 1, overflow: TextOverflow.ellipsis)),
      body: v == null
          ? (_error != null ? ErrorState(title: _error!, onRetry: _load) : const Padding(padding: EdgeInsets.all(20), child: SkeletonProfile(cards: 2)))
          : ListView(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 40),
              children: [
                Row(children: [
                  CommunityAvatar(name: c!.name, photoUrl: c.photoUrl, size: 72),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(c.name, maxLines: 2, overflow: TextOverflow.ellipsis, style: AppText.headline.copyWith(fontSize: 20)),
                      const SizedBox(height: 6),
                      Wrap(spacing: 8, runSpacing: 6, children: [
                        VisibilityChip(isPublic: c.isPublic),
                        InfoPill(icon: Icons.people_alt_outlined, text: '${c.memberCount} ${c.memberCount == 1 ? 'member' : 'members'}'),
                      ]),
                    ]),
                  ),
                ]),
                if (c.description.isNotEmpty) ...[
                  const SizedBox(height: 14),
                  Text(c.description, style: AppText.body.copyWith(color: AppTheme.text2)),
                ],
                const SizedBox(height: 18),
                if (c.status == 'REQUESTED') ...[
                  DsCard(tinted: true, child: Text('Request sent. An admin of ${c.name} will let you in.', style: AppText.body)),
                  const SizedBox(height: 10),
                  DsButton(key: const Key('community_cancel_request'), label: 'Cancel request', tone: DsButtonTone.outline, onPressed: _cancel),
                ] else if (c.status != 'MEMBER' && !c.club)
                  DsButton(
                    key: const Key('community_join'),
                    label: _busy ? 'Please wait…' : (c.isPublic ? 'Join community' : 'Ask to join'),
                    icon: c.isPublic ? Icons.group_add_rounded : Icons.lock_open_rounded,
                    onPressed: _busy ? null : _join,
                  ),
                if (!v.open) ...[
                  const SizedBox(height: 14),
                  Text('Members, rides and polls are visible after an admin lets you in.', textAlign: TextAlign.center, style: AppText.caption),
                ] else ...[
                  if (v.rides.isNotEmpty) ...[
                    const SizedBox(height: Space.s24),
                    const DsSectionHeader('Upcoming rides'),
                    const SizedBox(height: Space.s8),
                    for (final r in v.rides.where((r) => !r.past && !r.cancelled)) _RideCard(ride: r, member: false, onAnswer: null, onMenu: null),
                  ],
                  const SizedBox(height: Space.s24),
                  DsSectionHeader('Members (${v.members.length})'),
                  const SizedBox(height: Space.s8),
                  DsCard(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                    child: Column(children: [
                      for (var i = 0; i < v.members.length; i++)
                        DsListRow(
                          icon: Icons.person_rounded,
                          label: v.members[i].$1.username,
                          value: v.members[i].$2 == 'ADMIN' ? 'Admin' : v.members[i].$2 == 'CO_ADMIN' ? 'Co-admin' : null,
                          divider: i < v.members.length - 1,
                          onTap: () => RiderProfileScreen.open(context, v.members[i].$1.username),
                        ),
                    ]),
                  ),
                ],
              ],
            ),
    );
  }
}
