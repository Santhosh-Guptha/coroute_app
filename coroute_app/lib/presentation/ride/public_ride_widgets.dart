import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_theme.dart';
import '../../core/ui/ui.dart';
import '../../data/models/public_ride_models.dart';
import '../../data/services/public_ride_service.dart';

/// Public ride: ride settings (host), my own choices, map markers, the HUD (road warnings,
/// requests, open chats) and the contact / warning sheets. Wording kept short and plain.
class PublicRideTexts {
  PublicRideTexts._();

  static const String title = 'Public ride';
  static const String explain = 'Riders nearby can see this ride and contact you safely. Never your phone number.';
  static const String hostOnly = 'The trip owner or trip head decides.';
  static const String rough = 'Others see a rough location (about 500 m) and heading. Hidden when parked over 10 minutes.';
  static const String showName = 'Show ride name';
  static const String showNameOff = 'Shown as "Rider" or "Group of N".';
  static const String showRegion = 'Show destination region';
  static const String nearMe = 'Show public rides near me';
  static const String nearMeOnRide = 'On: your ride is public.';
  static const String roadWarnings = 'Road warnings';
  static const String roadWarningsExplain = 'Warn and be warned about the road by riders coming the other way.';
  static const String noPii = 'Only quick messages. No phone numbers or names unless you share them.';
  static const String warnTitle = 'Warn riders coming this way';
}

// ===================================================================== settings
class PublicRideSettingsCard extends StatelessWidget {
  final bool lead;
  const PublicRideSettingsCard({super.key, required this.lead});

  @override
  Widget build(BuildContext context) {
    final s = Provider.of<PublicRideService?>(context);
    if (s == null || !s.available) return const SizedBox.shrink();
    final rs = s.settings;
    final p = s.prefs;

    void setRide(PublicRideSettings next) {
      if (!s.setRideSettings(next)) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(const SnackBar(content: Text('Could not change this now. Try again with signal.')));
      }
    }

    Widget radii(int value, ValueChanged<int>? onPick) => Wrap(
          spacing: Space.s8,
          children: [
            for (final km in PublicRideWire.radii)
              ChoiceChip(
                label: Text('$km km'),
                selected: value == km,
                materialTapTargetSize: MaterialTapTargetSize.padded,
                onSelected: onPick == null ? null : (_) => onPick(km),
              ),
          ],
        );

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Divider(),
        SwitchListTile(
          key: const Key('public_ride_switch'),
          contentPadding: EdgeInsets.zero,
          secondary: Icon(Icons.public_rounded, color: AppTheme.accentText),
          title: Text(PublicRideTexts.title, style: AppText.body.copyWith(fontWeight: FontWeight.w700)),
          subtitle: Text(lead ? PublicRideTexts.explain : '${PublicRideTexts.explain} ${PublicRideTexts.hostOnly}', style: AppText.caption),
          value: rs.on,
          onChanged: lead ? (v) => setRide(rs.copyWith(on: v)) : null,
        ),
        if (rs.on) ...[
          Text('Visible within', style: AppText.label),
          radii(rs.radiusKm, lead ? (km) => setRide(rs.copyWith(radiusKm: km)) : null),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(PublicRideTexts.showName, style: AppText.body),
            subtitle: rs.showName ? null : Text(PublicRideTexts.showNameOff, style: AppText.caption),
            value: rs.showName,
            onChanged: lead ? (v) => setRide(rs.copyWith(showName: v)) : null,
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(PublicRideTexts.showRegion, style: AppText.body),
            value: rs.showDestRegion,
            onChanged: lead ? (v) => setRide(rs.copyWith(showDestRegion: v)) : null,
          ),
          Text(PublicRideTexts.rough, style: AppText.caption),
          const SizedBox(height: Space.s8),
        ],
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(PublicRideTexts.nearMe, style: AppText.body.copyWith(fontWeight: FontWeight.w600)),
          subtitle: rs.on ? Text(PublicRideTexts.nearMeOnRide, style: AppText.caption) : null,
          value: rs.on || p.showNearby,
          onChanged: rs.on ? null : (v) => s.setPrefs(p.copyWith(showNearby: v)),
        ),
        if (!rs.on && p.showNearby) radii(p.radiusKm, (km) => s.setPrefs(p.copyWith(radiusKm: km))),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(PublicRideTexts.roadWarnings, style: AppText.body.copyWith(fontWeight: FontWeight.w600)),
          subtitle: Text(rs.on ? '${PublicRideTexts.roadWarningsExplain} On with Public ride.' : PublicRideTexts.roadWarningsExplain, style: AppText.caption),
          value: rs.on || p.roadWarnings,
          onChanged: rs.on ? null : (v) => s.setPrefs(p.copyWith(roadWarnings: v)),
        ),
      ],
    );
  }
}

// ===================================================================== map
/// Public rides, road warnings and a chat partner's shared location, as map markers.
class PublicRideMarkerLayer extends StatelessWidget {
  final void Function(PublicRideMarker ride) onTapRide;
  final void Function(RoadWarning w)? onTapWarning;
  const PublicRideMarkerLayer({super.key, required this.onTapRide, this.onTapWarning});

  static const double width = 92, height = 36;

  @override
  Widget build(BuildContext context) {
    final s = Provider.of<PublicRideService?>(context);
    if (s == null) return const SizedBox.shrink();
    final rides = s.rides;
    final warnings = s.warnings;
    final shared = s.channels.where((c) => c.theirLat != null && c.theirLng != null).toList();
    if (rides.isEmpty && warnings.isEmpty && shared.isEmpty) return const SizedBox.shrink();
    return MarkerLayer(rotate: true, markers: [
      for (final r in rides)
        Marker(
          point: LatLng(r.lat, r.lng),
          width: width,
          height: height,
          child: PublicRideChip(ride: r, onTap: () => onTapRide(r)),
        ),
      for (final w in warnings)
        Marker(
          point: LatLng(w.lat, w.lng),
          width: 40,
          height: 40,
          child: Semantics(
            label: w.bannerText,
            button: onTapWarning != null,
            child: GestureDetector(
              onTap: onTapWarning == null ? null : () => onTapWarning!(w),
              child: Icon(Icons.warning_rounded, size: 34, color: w.confirmed ? StatusColors.critical : StatusColors.warning),
            ),
          ),
        ),
      for (final c in shared)
        Marker(
          point: LatLng(c.theirLat!, c.theirLng!),
          width: 40,
          height: 40,
          child: Semantics(label: '${c.withLabel}, shared location', child: Icon(Icons.person_pin_circle_rounded, size: 36, color: AppTheme.devmonksPurple)),
        ),
    ]);
  }
}

/// The distinct public-ride marker: a purple pill "8 km" with a group icon.
class PublicRideChip extends StatelessWidget {
  final PublicRideMarker ride;
  final VoidCallback? onTap;
  const PublicRideChip({super.key, required this.ride, this.onTap});

  @override
  Widget build(BuildContext context) {
    final color = AppTheme.devmonksPurple;
    return Semantics(
      label: ride.markerLabel,
      button: onTap != null,
      child: GestureDetector(
        onTap: onTap,
        child: Center(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: Colors.white, width: 2),
              boxShadow: dsFloatingShadow(),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(ride.riders > 1 ? Icons.groups_rounded : Icons.two_wheeler_rounded, size: 16, color: Colors.white),
                const SizedBox(width: 4),
                Text('${ride.distanceKm} km', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 13)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ===================================================================== HUD
/// Road warnings ahead, requests to my ride, open chats and the "Warn riders" button.
class PublicRideHud extends StatefulWidget {
  const PublicRideHud({super.key});

  @override
  State<PublicRideHud> createState() => _PublicRideHudState();
}

class _PublicRideHudState extends State<PublicRideHud> {
  final Set<String> _hidden = {};
  int _noticeSeen = 0;

  @override
  Widget build(BuildContext context) {
    final s = Provider.of<PublicRideService?>(context);
    if (s == null || !s.available) return const SizedBox.shrink();
    if (s.noticeSeq != _noticeSeen) {
      _noticeSeen = s.noticeSeq;
      final text = s.notice;
      if (text != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(text)));
        });
      }
    }
    final warnings = s.warnings.where((w) => !_hidden.contains(w.warnId)).take(2).toList();
    final requests = s.incoming.where((q) => !_hidden.contains(q.requestId)).take(1).toList();
    final chats = s.channels;
    final replies = s.outgoing.where((o) => o.state == OutgoingState.sent && o.replies.isNotEmpty && !_hidden.contains(o.requestId)).take(1).toList();
    final children = <Widget>[
      for (final w in warnings) RoadWarningBanner(warning: w, onHide: () => setState(() => _hidden.add(w.warnId))),
      for (final q in requests) ContactRequestCard(request: q, onHide: () => setState(() => _hidden.add(q.requestId))),
      for (final o in replies)
        _HudCard(
          icon: Icons.chat_bubble_rounded,
          title: o.rideLabel,
          body: o.replies.last.display,
          onClose: () => setState(() => _hidden.add(o.requestId)),
        ),
      if (chats.isNotEmpty || s.roadWarningsOn)
        Align(
          alignment: Alignment.centerRight,
          child: Wrap(
            spacing: Space.s8,
            runSpacing: Space.s4,
            alignment: WrapAlignment.end,
            children: [
              for (final c in chats)
                ActionChip(
                  avatar: const Icon(Icons.forum_rounded, size: 18),
                  label: Text('${c.withLabel} · ${c.minutesLeft(DateTime.now().millisecondsSinceEpoch)} min'),
                  onPressed: () => showContactChannelSheet(context, c.channelId),
                ),
              if (s.roadWarningsOn)
                ActionChip(
                  key: const Key('warn_riders_chip'),
                  avatar: const Icon(Icons.campaign_rounded, size: 18),
                  label: const Text('Warn riders'),
                  onPressed: () => showRoadWarnSheet(context),
                ),
            ],
          ),
        ),
    ];
    if (children.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: Space.s8),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        for (final c in children) Padding(padding: const EdgeInsets.only(bottom: Space.s8), child: c),
      ]),
    );
  }
}

class _HudCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String body;
  final Color? color;
  final VoidCallback? onClose;
  final List<Widget> actions;
  const _HudCard({required this.icon, required this.title, required this.body, this.color, this.onClose, this.actions = const []});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppTheme.card.withValues(alpha: 0.97),
      borderRadius: BorderRadius.circular(Radii.md),
      elevation: 3,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(padding: const EdgeInsets.only(top: 2), child: Icon(icon, color: color ?? AppTheme.accentText, size: 22)),
                const SizedBox(width: Space.s8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(title, maxLines: 2, overflow: TextOverflow.ellipsis, style: AppText.body.copyWith(fontWeight: FontWeight.w700)),
                      if (body.isNotEmpty) Text(body, maxLines: 3, overflow: TextOverflow.ellipsis, style: AppText.caption),
                    ],
                  ),
                ),
                if (onClose != null)
                  IconButton(tooltip: 'Hide', visualDensity: VisualDensity.compact, onPressed: onClose, icon: const Icon(Icons.close_rounded, size: 20)),
              ],
            ),
            if (actions.isNotEmpty) Wrap(spacing: Space.s4, alignment: WrapAlignment.end, children: actions),
          ],
        ),
      ),
    );
  }
}

/// "Accident reported 6 km ahead by an oncoming rider" with Still there / Not there.
class RoadWarningBanner extends StatelessWidget {
  final RoadWarning warning;
  final VoidCallback? onHide;
  const RoadWarningBanner({super.key, required this.warning, this.onHide});

  @override
  Widget build(BuildContext context) {
    final s = context.read<PublicRideService>();
    final voted = context.select<PublicRideService, bool>((x) => x.hasVoted(warning.warnId));
    return _HudCard(
      icon: Icons.warning_rounded,
      color: warning.confirmed ? StatusColors.critical : StatusColors.warning,
      title: warning.bannerText,
      body: warning.confirmText,
      onClose: onHide,
      actions: voted
          ? const []
          : [
              TextButton(onPressed: () => s.vote(warning.warnId, stillThere: true), child: const Text('Still there')),
              TextButton(onPressed: () => s.vote(warning.warnId, stillThere: false), child: const Text('Not there')),
            ],
    );
  }
}

/// A request to my ride: Reply, Accept, Ignore, and Block / Report.
class ContactRequestCard extends StatelessWidget {
  final ContactRequest request;
  final VoidCallback? onHide;
  const ContactRequestCard({super.key, required this.request, this.onHide});

  @override
  Widget build(BuildContext context) {
    final s = context.read<PublicRideService>();
    final q = request;
    final icon = switch (q.kind) {
      ContactKind.hi => Icons.waving_hand_rounded,
      ContactKind.help => Icons.support_rounded,
      ContactKind.warn => Icons.warning_amber_rounded,
    };
    return _HudCard(
      icon: icon,
      color: q.kind == ContactKind.help ? StatusColors.warning : null,
      title: q.headline,
      body: q.text,
      onClose: onHide,
      actions: [
        TextButton(onPressed: () => showReplySheet(context, q), child: const Text('Reply')),
        TextButton(onPressed: () => s.reply(q.requestId, 'ACCEPT'), child: const Text('Accept')),
        TextButton(onPressed: () => s.reply(q.requestId, 'IGNORE'), child: const Text('Ignore')),
        PopupMenuButton<String>(
          tooltip: 'More',
          onSelected: (v) {
            if (v == 'BLOCK') s.reply(q.requestId, 'BLOCK');
            if (v == 'REPORT') showReportSheet(context, q.requestId, fromRequest: true);
          },
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'BLOCK', child: Text('Block for 30 days')),
            PopupMenuItem(value: 'REPORT', child: Text('Report')),
          ],
        ),
      ],
    );
  }
}

// ===================================================================== sheets
/// From a public-ride marker: Say hi, Ask for help or Warn about road ahead.
Future<void> showPublicRideSheet(BuildContext context, PublicRideMarker ride) {
  return showAppSheet<void>(
    context,
    title: ride.markerLabel,
    isScrollControlled: true,
    builder: (_) => _ContactComposer(ride: ride),
  );
}

class _ContactComposer extends StatefulWidget {
  final PublicRideMarker ride;
  const _ContactComposer({required this.ride});

  @override
  State<_ContactComposer> createState() => _ContactComposerState();
}

class _ContactComposerState extends State<_ContactComposer> {
  ContactKind? _kind;
  String? _quick;
  final _text = TextEditingController();
  String? _problem;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = context.read<PublicRideService>();
    final kind = _kind;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(widget.ride.detail, style: AppText.body),
        const SizedBox(height: Space.s4),
        Text(PublicRideTexts.noPii, style: AppText.caption),
        const SizedBox(height: Space.s12),
        if (kind == null)
          for (final k in ContactKind.values)
            Padding(
              padding: const EdgeInsets.only(bottom: Space.s8),
              child: DsButton(
                label: k.title,
                icon: switch (k) {
                  ContactKind.hi => Icons.waving_hand_rounded,
                  ContactKind.help => Icons.support_rounded,
                  ContactKind.warn => Icons.warning_amber_rounded,
                },
                tone: k == ContactKind.help ? DsButtonTone.warn : DsButtonTone.outline,
                onPressed: () => setState(() => _kind = k),
              ),
            )
        else ...[
          Text(kind.title, style: AppText.title),
          const SizedBox(height: Space.s8),
          Wrap(
            spacing: Space.s8,
            runSpacing: Space.s8,
            children: [
              for (final e in QuickLines.forKind(kind).entries)
                ChoiceChip(label: Text(e.value), selected: _quick == e.key, onSelected: (_) => setState(() => _quick = e.key)),
            ],
          ),
          const SizedBox(height: Space.s8),
          TextField(
            controller: _text,
            maxLength: PublicRideWire.textMax,
            decoration: InputDecoration(hintText: 'Add a few words (optional)', errorText: _problem),
            onChanged: (v) => setState(() => _problem = ContactText.problem(v)),
          ),
          DsButton(
            label: 'Send',
            icon: Icons.send_rounded,
            onPressed: _quick == null || _problem != null
                ? null
                : () {
                    if (s.contact(widget.ride, kind, _quick!, text: _text.text)) Navigator.of(context).maybePop();
                  },
          ),
          TextButton(onPressed: () => setState(() => _kind = null), child: const Text('Back')),
        ],
      ],
    );
  }
}

/// One-tap road warnings for riders coming toward this spot.
Future<void> showRoadWarnSheet(BuildContext context) {
  return showAppSheet<void>(
    context,
    title: PublicRideTexts.warnTitle,
    builder: (sheetCtx) {
      final s = sheetCtx.read<PublicRideService>();
      IconData icon(RoadWarningKind k) => switch (k) {
            RoadWarningKind.police => Icons.local_police_rounded,
            RoadWarningKind.accident => Icons.car_crash_rounded,
            RoadWarningKind.blocked => Icons.block_rounded,
            RoadWarningKind.animals => Icons.pets_rounded,
            RoadWarningKind.fuelClosed => Icons.local_gas_station_rounded,
            RoadWarningKind.weather => Icons.foggy,
          };
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Sent from where you are now. Shows widely once another rider confirms it.', style: AppText.caption),
          const SizedBox(height: Space.s12),
          GridView.count(
            crossAxisCount: 2,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            mainAxisSpacing: Space.s8,
            crossAxisSpacing: Space.s8,
            childAspectRatio: 2.6,
            children: [
              for (final k in RoadWarningKind.values)
                DsButton(
                  label: k.buttonLabel,
                  icon: icon(k),
                  height: 64,
                  fontSize: 14,
                  tone: k == RoadWarningKind.accident || k == RoadWarningKind.blocked ? DsButtonTone.warn : DsButtonTone.outline,
                  onPressed: () {
                    s.sendRoadWarning(k);
                    Navigator.of(sheetCtx).maybePop();
                  },
                ),
            ],
          ),
        ],
      );
    },
  );
}

/// Quick reply to a request (or Accept from here).
Future<void> showReplySheet(BuildContext context, ContactRequest q) {
  return showAppSheet<void>(
    context,
    title: q.headline,
    isScrollControlled: true,
    builder: (sheetCtx) {
      final s = sheetCtx.read<PublicRideService>();
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (q.text.isNotEmpty) Text('"${q.text}"', style: AppText.body),
          const SizedBox(height: Space.s8),
          Wrap(
            spacing: Space.s8,
            runSpacing: Space.s8,
            children: [
              for (final e in QuickLines.reply.entries)
                ActionChip(
                  label: Text(e.value),
                  onPressed: () {
                    s.reply(q.requestId, 'QUICK', quick: e.key);
                    Navigator.of(sheetCtx).maybePop();
                  },
                ),
            ],
          ),
          const SizedBox(height: Space.s12),
          DsButton(
            label: 'Accept (30 min chat)',
            icon: Icons.check_rounded,
            onPressed: () {
              s.reply(q.requestId, 'ACCEPT');
              Navigator.of(sheetCtx).maybePop();
            },
          ),
        ],
      );
    },
  );
}

/// An open chat: quick lines, my live location, my contact (only when I choose), report, block, end.
Future<void> showContactChannelSheet(BuildContext context, String channelId) {
  return showAppSheet<void>(
    context,
    title: 'Public ride chat',
    isScrollControlled: true,
    builder: (_) => _ChannelView(channelId: channelId),
  );
}

class _ChannelView extends StatefulWidget {
  final String channelId;
  const _ChannelView({required this.channelId});

  @override
  State<_ChannelView> createState() => _ChannelViewState();
}

class _ChannelViewState extends State<_ChannelView> {
  final _text = TextEditingController();
  String? _problem;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watch<PublicRideService>();
    final c = s.channel(widget.channelId);
    final now = DateTime.now().millisecondsSinceEpoch;
    if (c == null) return const SizedBox.shrink();
    final open = c.isOpen(now);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(open ? '${c.withLabel} · ${c.minutesLeft(now)} min left' : '${c.withLabel} · ended', style: AppText.title),
        const SizedBox(height: Space.s8),
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 220),
          child: ListView(
            shrinkWrap: true,
            children: [
              for (final l in c.lines)
                Align(
                  alignment: l.mine ? Alignment.centerRight : Alignment.centerLeft,
                  child: Container(
                    margin: const EdgeInsets.only(bottom: 6),
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(color: l.mine ? AppTheme.tint : AppTheme.soft, borderRadius: BorderRadius.circular(12)),
                    child: Text(l.display, style: AppText.body),
                  ),
                ),
            ],
          ),
        ),
        if (c.theirPhone != null) ...[
          const SizedBox(height: Space.s8),
          SelectableText('${c.theirName ?? 'They'} shared: ${c.theirPhone}', style: AppText.body.copyWith(fontWeight: FontWeight.w700)),
        ],
        if (c.theirLat != null) Text('${c.withLabel} is sharing their location (on your map).', style: AppText.caption),
        if (open) ...[
          const SizedBox(height: Space.s8),
          Wrap(
            spacing: Space.s8,
            runSpacing: Space.s8,
            children: [
              for (final e in QuickLines.reply.entries) ActionChip(label: Text(e.value), onPressed: () => s.say(c.channelId, quick: e.key)),
            ],
          ),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _text,
                  maxLength: PublicRideWire.textMax,
                  decoration: InputDecoration(hintText: 'Short message', errorText: _problem),
                  onChanged: (v) => setState(() => _problem = ContactText.problem(v)),
                ),
              ),
              IconButton(
                tooltip: 'Send',
                onPressed: _problem != null || _text.text.trim().isEmpty
                    ? null
                    : () {
                        if (s.say(c.channelId, text: _text.text)) _text.clear();
                      },
                icon: const Icon(Icons.send_rounded),
              ),
            ],
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text('Share my live location', style: AppText.body),
            subtitle: Text('Only with them, until this chat ends.', style: AppText.caption),
            value: c.sharingMine,
            onChanged: (v) => s.shareLocation(c.channelId, v),
          ),
          TextButton.icon(
            onPressed: () async {
              final ok = await showAppDialog<bool>(
                context, // round 7: app motion (spring scale + fade, reduce-motion aware)
                builder: (d) => AlertDialog(
                  title: const Text('Share your name and number?'),
                  content: const Text('They will see your first name and phone number.'),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancel')),
                    TextButton(onPressed: () => Navigator.pop(d, true), child: const Text('Share')),
                  ],
                ),
              );
              if (ok == true) s.shareContact(c.channelId);
            },
            icon: const Icon(Icons.contact_phone_rounded),
            label: const Text('Share my name and number'),
          ),
        ],
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          children: [
            TextButton(onPressed: () => showReportSheet(context, c.channelId), child: const Text('Report')),
            TextButton(onPressed: () => s.block(c.channelId), child: const Text('Block')),
            if (open) TextButton(onPressed: () => s.closeChannel(c.channelId), child: const Text('End chat')),
          ],
        ),
      ],
    );
  }
}

/// Report a request or chat: a reason, a short note, and optionally block.
Future<void> showReportSheet(BuildContext context, String ref, {bool fromRequest = false}) {
  return showAppSheet<void>(
    context,
    title: 'Report',
    isScrollControlled: true,
    builder: (_) => _ReportView(refId: ref, fromRequest: fromRequest),
  );
}

class _ReportView extends StatefulWidget {
  final String refId;
  final bool fromRequest;
  const _ReportView({required this.refId, required this.fromRequest});

  @override
  State<_ReportView> createState() => _ReportViewState();
}

class _ReportViewState extends State<_ReportView> {
  static const Map<String, String> reasons = {'ABUSE': 'Abusive', 'SPAM': 'Spam', 'UNSAFE': 'Made me feel unsafe', 'OTHER': 'Something else'};
  String _reason = 'ABUSE';
  bool _block = true;
  final _note = TextEditingController();

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = context.read<PublicRideService>();
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('The conversation goes to our safety team.', style: AppText.caption),
        Wrap(
          spacing: Space.s8,
          children: [
            for (final e in reasons.entries) ChoiceChip(label: Text(e.value), selected: _reason == e.key, onSelected: (_) => setState(() => _reason = e.key)),
          ],
        ),
        TextField(controller: _note, maxLength: 140, decoration: const InputDecoration(hintText: 'What happened (optional)')),
        CheckboxListTile(contentPadding: EdgeInsets.zero, value: _block, onChanged: (v) => setState(() => _block = v ?? false), title: const Text('Also block for 30 days')),
        DsButton(
          label: 'Send report',
          tone: DsButtonTone.sos,
          onPressed: () {
            if (widget.fromRequest) {
              s.reply(widget.refId, 'REPORT', reason: _reason, text: _note.text, block: _block);
            } else {
              s.report(widget.refId, _reason, note: _note.text, block: _block);
            }
            Navigator.of(context).maybePop();
          },
        ),
      ],
    );
  }
}
