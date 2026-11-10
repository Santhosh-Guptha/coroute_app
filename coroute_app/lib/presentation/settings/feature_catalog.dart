import 'package:flutter/material.dart';

// The Features guide content: every rider-facing feature in plain words.
//
// Keep it true to the code: add an entry only for a feature riders can
// actually use, and point FeatureInfo.settings at the screen that holds its
// real switch. The guide screen (FeaturesGuideScreen) only renders this list.

/// The sections of the guide, in display order.
enum FeatureGroup {
  riding('Riding', Icons.two_wheeler_rounded),
  safety('Safety', Icons.health_and_safety_rounded),
  talk('Talk', Icons.mic_rounded),
  group('Group', Icons.groups_rounded),
  maps('Maps & offline', Icons.map_rounded),
  trips('Trips & stories', Icons.history_rounded),
  account('Account & privacy', Icons.privacy_tip_rounded),
  membership('Your plan', Icons.card_membership_rounded);

  final String label;
  final IconData icon;
  const FeatureGroup(this.label, this.icon);
}

/// How much a feature uses the battery or mobile data.
enum Impact {
  none('None'),
  low('Low'),
  medium('Medium'),
  high('High'),

  /// The feature reduces use (data saver).
  saves('Saves');

  final String label;
  const Impact(this.label);
}

/// Where the feature's switch lives. The guide turns this into a
/// "Change in settings" button; [none] shows no button.
enum SettingsTarget {
  none,

  /// Profile > Settings (SettingsScreen): every rider switch in one place.
  settings,

  /// Settings > Permissions.
  permissions,

  /// Settings > Fuel (tank size and fuel left).
  fuel,

  /// Offline map packs.
  offlineMaps,

  /// Profile > Garage.
  garage,

  /// Profile > Membership & Plans.
  membership,

  /// Settings > Phone check.
  phoneCheck,

  /// Profile > Edit profile (name, bike, emergency contact, medical info).
  profile,
}

/// One feature in the guide.
class FeatureInfo {
  final String id;
  final FeatureGroup group;
  final IconData icon;

  /// Short name, at most about 4 words.
  final String name;

  /// One line: what it does.
  final String what;

  /// One line: when it works (internet, offline, headset...).
  final String when;

  final Impact battery;
  final Impact data;

  /// One line: what is shared and with whom ("Stays on your phone" when nothing is).
  final String privacy;

  /// Where to change it; [SettingsTarget.none] when there is no switch.
  final SettingsTarget settings;

  /// Optional pointer when the switch is not in a settings screen (e.g. lead-only).
  final String? changeHint;

  const FeatureInfo({
    required this.id,
    required this.group,
    required this.icon,
    required this.name,
    required this.what,
    required this.when,
    required this.battery,
    required this.data,
    required this.privacy,
    this.settings = SettingsTarget.none,
    this.changeHint,
  });

  /// True when [query] (already lower-cased) appears in any text of this entry.
  bool matches(String query) {
    if (query.isEmpty) return true;
    final hay = '$name $what $when $privacy ${group.label} ${changeHint ?? ''}'.toLowerCase();
    return query.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).every(hay.contains);
  }
}

/// All features, grouped by [FeatureInfo.group] (order within a group is the display order).
const List<FeatureInfo> featureCatalog = [
  // ---------------------------------------------------------------- Riding
  FeatureInfo(
    id: 'live_map',
    group: FeatureGroup.riding,
    icon: Icons.map_rounded,
    name: 'Live ride map',
    what: 'Shows everyone in your group on the map, with who is ahead or behind.',
    when: 'During a ride. Needs internet (or a shared hotspot).',
    battery: Impact.high,
    data: Impact.medium,
    privacy: 'Your location goes to your group only, while you ride.',
    settings: SettingsTarget.permissions,
  ),
  FeatureInfo(
    id: 'pre_ride_check',
    group: FeatureGroup.riding,
    icon: Icons.checklist_rounded,
    name: 'Pre-ride checklist',
    what: 'A quick list before you start: permissions, battery, helmet and papers.',
    when: 'Before each ride. Works offline.',
    battery: Impact.none,
    data: Impact.none,
    privacy: 'Stays on your phone.',
  ),
  FeatureInfo(
    id: 'data_saver',
    group: FeatureGroup.riding,
    icon: Icons.data_saver_on_rounded,
    name: 'Data saver',
    what: 'Uses less mobile data: lighter voice, fewer map updates, no weather check.',
    when: 'Always, once switched on.',
    battery: Impact.saves,
    data: Impact.saves,
    privacy: 'Nothing extra is shared.',
    settings: SettingsTarget.settings,
  ),
  FeatureInfo(
    id: 'tunnel',
    group: FeatureGroup.riding,
    icon: Icons.alt_route_rounded,
    name: 'Tunnel mode',
    what: 'Keeps your dot moving when GPS drops, like in tunnels.',
    when: 'Always on during a ride. Works offline.',
    battery: Impact.low,
    data: Impact.none,
    privacy: 'Stays on your phone.',
  ),
  FeatureInfo(
    id: 'lock_screen',
    group: FeatureGroup.riding,
    icon: Icons.screen_lock_portrait_rounded,
    name: 'Ride on lock screen',
    what: 'Shows group distances and the SOS button on your lock screen.',
    when: 'During a ride.',
    battery: Impact.low,
    data: Impact.none,
    privacy: 'Visible to anyone who sees your locked phone.',
    changeHint: 'Always on for your safety. No switch.',
  ),
  FeatureInfo(
    id: 'fuel',
    group: FeatureGroup.riding,
    icon: Icons.local_gas_station_rounded,
    name: 'Fuel reminder',
    what: 'Tells you when to refuel, based on your tank range.',
    when: 'During a ride. Works offline.',
    battery: Impact.none,
    data: Impact.none,
    privacy: 'Your fuel estimate is shared only if you turn sharing on.',
    settings: SettingsTarget.fuel,
  ),
  FeatureInfo(
    id: 'essentials',
    group: FeatureGroup.riding,
    icon: Icons.local_pharmacy_rounded,
    name: 'Stops on the way',
    what: 'Fuel, food, ATMs, pharmacies and repair shops along your route.',
    when: 'Needs internet. The last list stays available offline.',
    battery: Impact.low,
    data: Impact.low,
    privacy: 'Your route area is sent to CoRoute to find places.',
  ),
  FeatureInfo(
    id: 'weather_dark',
    group: FeatureGroup.riding,
    icon: Icons.wb_twilight_rounded,
    name: 'Rain and dark warnings',
    what: 'Warns about rain on your route and when it gets dark.',
    when: 'Needs internet. Skipped in data saver.',
    battery: Impact.none,
    data: Impact.low,
    privacy: 'Route points are sent to get the weather. No names.',
  ),
  FeatureInfo(
    id: 'speed_warning',
    group: FeatureGroup.riding,
    icon: Icons.speed_rounded,
    name: 'Speed warning',
    what: 'Warns you when you ride above the speed you set.',
    when: 'During a ride. Works offline.',
    battery: Impact.none,
    data: Impact.none,
    privacy: 'Group speed limit breaks are shown on the group timeline.',
    settings: SettingsTarget.settings,
  ),
  FeatureInfo(
    id: 'remote',
    group: FeatureGroup.riding,
    icon: Icons.settings_remote_rounded,
    name: 'Handlebar remote',
    what: 'Use a Bluetooth button to talk, mark a hazard, or send SOS.',
    when: 'Needs a paired Bluetooth remote.',
    battery: Impact.low,
    data: Impact.none,
    privacy: 'Stays on your phone.',
    changeHint: 'Turn it on in the Talk panel during a group ride.',
  ),
  FeatureInfo(
    id: 'garage',
    group: FeatureGroup.riding,
    icon: Icons.garage_rounded,
    name: 'Garage',
    what: 'Keep your bikes, odometer and service dates in one place. Your active bike sets your fuel range and engine rest advice.',
    when: 'Any time. Works offline.',
    battery: Impact.none,
    data: Impact.none,
    privacy: 'Your bikes are kept on your phone. Your group sees your active bike\'s colour, and a short summary '
        '(model, engine size, tank and mileage) is shared with CoRoute to improve fuel and engine advice.',
    settings: SettingsTarget.garage,
  ),
  FeatureInfo(
    id: 'night_mode',
    group: FeatureGroup.riding,
    icon: Icons.dark_mode_rounded,
    name: 'Night mode',
    what: 'Light or dark look: automatic by sunrise and sunset, or your choice.',
    when: 'Any time.',
    battery: Impact.saves,
    data: Impact.none,
    privacy: 'Stays on your phone.',
    settings: SettingsTarget.settings,
  ),

  // ---------------------------------------------------------------- Safety
  FeatureInfo(
    id: 'sos',
    group: FeatureGroup.safety,
    icon: Icons.sos_rounded,
    name: 'SOS',
    what: 'Hold the SOS button to alert your group with your location.',
    when: 'Best with internet. Without it, it waits and can send texts.',
    battery: Impact.low,
    data: Impact.low,
    privacy: 'Your location goes to your group and emergency contact.',
    settings: SettingsTarget.profile,
  ),
  FeatureInfo(
    id: 'crash',
    group: FeatureGroup.safety,
    icon: Icons.car_crash_rounded,
    name: 'Crash detection',
    what: 'If the phone senses a crash, it rings for 30 s, then sends SOS.',
    when: 'During a ride (also a solo ride without internet), from about 12 km/h.',
    battery: Impact.medium,
    data: Impact.none,
    privacy: 'Nothing is sent if you tap I\'m OK in time.',
    changeHint: 'Always on for your safety. No switch.',
  ),
  FeatureInfo(
    id: 'sms',
    group: FeatureGroup.safety,
    icon: Icons.sms_rounded,
    name: 'Emergency texts',
    what: 'If SOS cannot go online, your phone texts a map link.',
    when: 'Needs phone signal. SMS charges apply.',
    battery: Impact.none,
    data: Impact.none,
    privacy: 'Your contact, the lead and nearby riders (up to 10) get your location.',
    changeHint: 'Always on for your safety. No switch.',
  ),
  FeatureInfo(
    id: 'checkin',
    group: FeatureGroup.safety,
    icon: Icons.person_search_rounded,
    name: 'Check on me',
    what: 'After 15 min far from the group, asks if you are OK.',
    when: 'During a group ride.',
    battery: Impact.none,
    data: Impact.low,
    privacy: 'If you do not answer in 2 min, your lead is told.',
    changeHint: 'Always on for your safety. No switch.',
  ),
  FeatureInfo(
    id: 'break',
    group: FeatureGroup.safety,
    icon: Icons.free_breakfast_rounded,
    name: 'Break reminder',
    what: 'After 2 h of riding without a 10 min stop, reminds you to rest.',
    when: 'During a ride. Works offline.',
    battery: Impact.none,
    data: Impact.none,
    privacy: 'Only you see it.',
    changeHint: 'Always on for your safety. No switch.',
  ),
  FeatureInfo(
    id: 'road_warnings',
    group: FeatureGroup.safety,
    icon: Icons.warning_amber_rounded,
    name: 'Road warnings',
    what: 'Warns you about accidents and road hazards ahead on your road.',
    when: 'During a ride. Needs internet.',
    battery: Impact.low,
    data: Impact.low,
    privacy: 'No names are shown.',
    changeHint: 'Always on for your safety. No switch.',
  ),
  FeatureInfo(
    id: 'medical',
    group: FeatureGroup.safety,
    icon: Icons.medical_information_rounded,
    name: 'Medical ID',
    what: 'Blood group, allergies and contact for people who help you.',
    when: 'Shown during an SOS. Works offline.',
    battery: Impact.none,
    data: Impact.none,
    privacy: 'Your group sees it in an SOS, and on your lock screen during it.',
    settings: SettingsTarget.profile,
  ),
  FeatureInfo(
    id: 'nearby_help',
    group: FeatureGroup.safety,
    icon: Icons.volunteer_activism_rounded,
    name: 'Nearby rider help',
    what: 'In an accident, riders from other groups close by can be asked to help.',
    when: 'Needs internet.',
    battery: Impact.none,
    data: Impact.low,
    privacy: 'Name and bike shared only after a rider accepts. Never your phone number.',
    settings: SettingsTarget.settings,
  ),
  FeatureInfo(
    id: 'report_down',
    group: FeatureGroup.safety,
    icon: Icons.personal_injury_rounded,
    name: 'Report a rider down',
    what: 'Long-press the map to report someone hurt at that spot.',
    when: 'During a ride. Sent when you are back online.',
    battery: Impact.none,
    data: Impact.low,
    privacy: 'Your group sees the spot you marked.',
  ),
  FeatureInfo(
    id: 'battery_guide',
    group: FeatureGroup.safety,
    icon: Icons.battery_alert_rounded,
    name: 'Keep app running',
    what: 'Steps for your phone brand so it does not close CoRoute mid-ride.',
    when: 'One-time setup.',
    battery: Impact.medium,
    data: Impact.none,
    privacy: 'Nothing is shared.',
    settings: SettingsTarget.permissions,
  ),

  // ---------------------------------------------------------------- Talk
  FeatureInfo(
    id: 'talk',
    group: FeatureGroup.talk,
    icon: Icons.record_voice_over_rounded,
    name: 'Group talk',
    what: 'Hold to talk to the whole group, or to one rider.',
    when: 'Needs internet. A headset works best.',
    battery: Impact.medium,
    data: Impact.medium,
    privacy: 'Your voice goes live to your group only.',
    settings: SettingsTarget.permissions,
  ),
  FeatureInfo(
    id: 'hands_free',
    group: FeatureGroup.talk,
    icon: Icons.hearing_rounded,
    name: 'Hands-free talk',
    what: 'Sends your voice only while you speak. No button needed.',
    when: 'Needs internet and a headset mic.',
    battery: Impact.medium,
    data: Impact.medium,
    privacy: 'The mic stays open until you turn it off.',
  ),
  FeatureInfo(
    id: 'lead_priority',
    group: FeatureGroup.talk,
    icon: Icons.volume_down_rounded,
    name: 'Lead voice first',
    what: 'Other voices get quieter when the lead speaks.',
    when: 'Automatic during group talk.',
    battery: Impact.none,
    data: Impact.none,
    privacy: 'Nothing extra is shared.',
  ),
  FeatureInfo(
    id: 'spoken_alerts',
    group: FeatureGroup.talk,
    icon: Icons.campaign_rounded,
    name: 'Spoken alerts',
    what: 'Reads out warnings and directions. Emergencies are always spoken.',
    when: 'During a ride. Works offline.',
    battery: Impact.low,
    data: Impact.none,
    privacy: 'Played on your phone or headset only.',
    settings: SettingsTarget.settings,
  ),
  FeatureInfo(
    id: 'quick_messages',
    group: FeatureGroup.talk,
    icon: Icons.quickreply_rounded,
    name: 'Quick messages',
    what: 'Send a ready message like "Fuel stop" or "Wait for me" in one tap.',
    when: 'Needs internet.',
    battery: Impact.none,
    data: Impact.low,
    privacy: 'Your group sees the message.',
  ),
  FeatureInfo(
    id: 'language',
    group: FeatureGroup.talk,
    icon: Icons.translate_rounded,
    name: 'Language',
    what: 'English, Hindi or Telugu for safety screens and spoken alerts.',
    when: 'Any time.',
    battery: Impact.none,
    data: Impact.none,
    privacy: 'Stays on your phone.',
    settings: SettingsTarget.settings,
  ),

  // ---------------------------------------------------------------- Group
  FeatureInfo(
    id: 'join',
    group: FeatureGroup.group,
    icon: Icons.group_add_rounded,
    name: 'Start or join',
    what: 'Start a ride, or join one with the code from the trip owner.',
    when: 'Needs internet.',
    battery: Impact.none,
    data: Impact.low,
    privacy: 'Your name and bike are shown to the group.',
  ),
  FeatureInfo(
    id: 'roles',
    group: FeatureGroup.group,
    icon: Icons.flag_rounded,
    name: 'Riding roles',
    what: 'Riding positions in the group. The lead rides first and guides the group. Middle riders keep the rider ahead in sight. '
        'The sweeper rides last so no one is left behind. Riders are told when their role changes. '
        'Not the same as the trip owner (who created the trip) or the trip head (can change the trip\'s settings).',
    when: 'During a group ride.',
    battery: Impact.none,
    data: Impact.none,
    privacy: 'Roles are shown to the group.',
    changeHint: 'Automatic roles follow the order on the road (Group settings). The trip owner or the Lead can also set a role from a rider\'s card.',
  ),
  FeatureInfo(
    id: 'group_alerts',
    group: FeatureGroup.group,
    icon: Icons.notifications_active_rounded,
    name: 'Group alerts',
    what: 'Tells the group when someone falls behind, stops, or speeds.',
    when: 'During a group ride. Needs internet.',
    battery: Impact.none,
    data: Impact.low,
    privacy: 'Your group sees these alerts.',
    changeHint: 'The trip owner or trip head changes limits in Group settings during a ride.',
  ),
  FeatureInfo(
    id: 'meet_here',
    group: FeatureGroup.group,
    icon: Icons.place_rounded,
    name: 'Meeting point',
    what: 'Long-press the map to set a meeting point or suggest a stop.',
    when: 'During a group ride.',
    battery: Impact.none,
    data: Impact.low,
    privacy: 'Your group sees the point.',
  ),
  FeatureInfo(
    id: 'timeline',
    group: FeatureGroup.group,
    icon: Icons.timeline_rounded,
    name: 'Ride timeline',
    what: 'A list of what happened: stops, alerts, SOS and who was involved.',
    when: 'During and after a group ride.',
    battery: Impact.none,
    data: Impact.low,
    privacy: 'Only your group can see it.',
  ),
  FeatureInfo(
    id: 'guardian',
    group: FeatureGroup.group,
    icon: Icons.shield_rounded,
    name: 'Ride Guardian',
    what: 'Share a link so family can follow your ride in a browser.',
    when: 'During a ride. Needs internet.',
    battery: Impact.none,
    data: Impact.low,
    privacy: 'Anyone with the link sees what you chose, until it expires.',
    changeHint: 'Open it from Group settings during a ride.',
  ),
  FeatureInfo(
    id: 'group_fuel',
    group: FeatureGroup.group,
    icon: Icons.local_gas_station_rounded,
    name: 'Group fuel stop',
    what: 'Picks a fuel stop that works for everyone\'s range.',
    when: 'During a group ride. Only riders who share fuel count.',
    battery: Impact.none,
    data: Impact.low,
    privacy: 'Your fuel estimate is shared only if you turn sharing on.',
    settings: SettingsTarget.fuel,
  ),
  FeatureInfo(
    id: 'discovery',
    group: FeatureGroup.group,
    icon: Icons.waving_hand_rounded,
    name: 'Nearby groups',
    what: 'See and wave to other public groups riding near you.',
    when: 'Only when both groups are public. Needs internet.',
    battery: Impact.none,
    data: Impact.low,
    privacy: 'Only group name and rider count. Never positions.',
    changeHint: 'The trip owner or trip head turns it on in Group settings.',
  ),
  FeatureInfo(
    id: 'nearby_link',
    group: FeatureGroup.group,
    icon: Icons.wifi_tethering_rounded,
    name: 'No-internet link',
    what: 'Phones on the same hotspot share positions and SOS without internet.',
    when: 'Riders must be on the same Wi-Fi hotspot.',
    battery: Impact.medium,
    data: Impact.none,
    privacy: 'Shared only with phones on that hotspot.',
  ),

  // ---------------------------------------------------------------- Maps & offline
  FeatureInfo(
    id: 'offline_maps',
    group: FeatureGroup.maps,
    icon: Icons.download_for_offline_rounded,
    name: 'Offline maps',
    what: 'Download the map along your route to use without signal.',
    when: 'Download with internet. Use offline.',
    battery: Impact.none,
    data: Impact.high,
    privacy: 'Maps are saved on your phone.',
    settings: SettingsTarget.offlineMaps,
  ),
  FeatureInfo(
    id: 'save_maps_wifi',
    group: FeatureGroup.maps,
    icon: Icons.wifi_rounded,
    name: 'Save maps on Wi-Fi',
    what: 'Saves the route map before the ride (about 12 MB, kept 30 days).',
    when: 'Automatic on Wi-Fi, not in data saver.',
    battery: Impact.low,
    data: Impact.none,
    privacy: 'Maps are saved on your phone.',
  ),
  FeatureInfo(
    id: 'map_memory',
    group: FeatureGroup.maps,
    icon: Icons.layers_rounded,
    name: 'Map memory',
    what: 'Map areas you have seen once show again without data.',
    when: 'Automatic. Works offline.',
    battery: Impact.none,
    data: Impact.saves,
    privacy: 'Stays on your phone.',
  ),
  FeatureInfo(
    id: 'trip_planner',
    group: FeatureGroup.maps,
    icon: Icons.edit_road_rounded,
    name: 'Trip planner',
    what: 'Plan a route with stops before the ride.',
    when: 'Needs internet to plan.',
    battery: Impact.none,
    data: Impact.low,
    privacy: 'Your group sees the planned route.',
  ),
  FeatureInfo(
    id: 'gpx',
    group: FeatureGroup.maps,
    icon: Icons.ios_share_rounded,
    name: 'Export route',
    what: 'Share the route as a GPX file for other map apps.',
    when: 'Any time. Works offline.',
    battery: Impact.none,
    data: Impact.none,
    privacy: 'Goes only where you share it.',
  ),

  // ---------------------------------------------------------------- Trips & stories
  FeatureInfo(
    id: 'history',
    group: FeatureGroup.trips,
    icon: Icons.history_rounded,
    name: 'Ride history',
    what: 'Your past rides with distance, time and stops.',
    when: 'Any time. Full report needs internet.',
    battery: Impact.none,
    data: Impact.low,
    privacy: 'Your route is saved to your account.',
  ),
  FeatureInfo(
    id: 'replay',
    group: FeatureGroup.trips,
    icon: Icons.replay_rounded,
    name: 'Ride replay',
    what: 'Watch your ride play back on the map.',
    when: 'After a ride.',
    battery: Impact.none,
    data: Impact.low,
    privacy: 'Only you see it.',
  ),
  FeatureInfo(
    id: 'share_card',
    group: FeatureGroup.trips,
    icon: Icons.image_rounded,
    name: 'Share card',
    what: 'Make a picture of your ride to share.',
    when: 'After a ride.',
    battery: Impact.none,
    data: Impact.none,
    privacy: 'Goes only where you share it.',
  ),
  FeatureInfo(
    id: 'reviews',
    group: FeatureGroup.trips,
    icon: Icons.rate_review_rounded,
    name: 'Ride reviews',
    what: 'Tell other riders about the ride.',
    when: 'After a ride. Needs internet.',
    battery: Impact.none,
    data: Impact.low,
    privacy: 'Public only after a check by the CoRoute team.',
  ),

  // ---------------------------------------------------------------- Account & privacy
  FeatureInfo(
    id: 'profile',
    group: FeatureGroup.account,
    icon: Icons.badge_rounded,
    name: 'Profile and contact',
    what: 'Your name, bike, blood group and emergency contact.',
    when: 'Any time. Needs internet to save.',
    battery: Impact.none,
    data: Impact.low,
    privacy: 'Your group sees your name and bike.',
    settings: SettingsTarget.profile,
  ),
  FeatureInfo(
    id: 'permissions',
    group: FeatureGroup.account,
    icon: Icons.verified_user_rounded,
    name: 'Permissions',
    what: 'Location, mic, notifications, battery and texts, and why each is needed.',
    when: 'Any time.',
    battery: Impact.none,
    data: Impact.none,
    privacy: 'Used only during a ride.',
    settings: SettingsTarget.permissions,
  ),
  FeatureInfo(
    id: 'phone_check',
    group: FeatureGroup.account,
    icon: Icons.phonelink_setup_rounded,
    name: 'Phone check',
    what: 'Tests GPS, sensors and battery settings before a ride.',
    when: 'Any time. Works offline.',
    battery: Impact.none,
    data: Impact.none,
    privacy: 'A report is sent only if you agree. No contacts or messages.',
    settings: SettingsTarget.phoneCheck,
  ),
  FeatureInfo(
    id: 'report_problem',
    group: FeatureGroup.account,
    icon: Icons.bug_report_rounded,
    name: 'Report a problem',
    what: 'Tell us what went wrong. We reply by e-mail.',
    when: 'Needs internet.',
    battery: Impact.none,
    data: Impact.low,
    privacy: 'Sends your e-mail, app version and phone type.',
  ),
  FeatureInfo(
    id: 'delete_account',
    group: FeatureGroup.account,
    icon: Icons.delete_forever_rounded,
    name: 'Delete account',
    what: 'Removes your account, profile and ride history for good.',
    when: 'Needs internet.',
    battery: Impact.none,
    data: Impact.none,
    privacy: 'Your data is deleted from CoRoute.',
  ),

  // ---------------------------------------------------------------- Membership
  FeatureInfo(
    id: 'plans',
    group: FeatureGroup.membership,
    icon: Icons.card_membership_rounded,
    name: 'Plan and riders',
    what: 'Solo riding and every safety feature are free. A group plan sets how many riders you can host.',
    when: 'Your plan is managed in your CoRoute account.',
    battery: Impact.none,
    data: Impact.none,
    privacy: 'The app only reads your plan name, riders and end date.',
    settings: SettingsTarget.membership,
  ),
  FeatureInfo(
    id: 'group_seats',
    group: FeatureGroup.membership,
    icon: Icons.event_seat_rounded,
    name: 'Group seats',
    what: 'Riders you add to your plan ride free.',
    when: 'While the plan is active.',
    battery: Impact.none,
    data: Impact.none,
    privacy: 'Seat holders see the plan name and owner.',
    settings: SettingsTarget.membership,
  ),
  FeatureInfo(
    id: 'ride_safe_on_expiry',
    group: FeatureGroup.membership,
    icon: Icons.verified_rounded,
    name: 'Safety always on',
    what: 'SOS and crash detection keep working, even if a plan ends mid-ride.',
    when: 'Always.',
    battery: Impact.none,
    data: Impact.none,
    privacy: 'Nothing extra is shared.',
  ),
];
