import '../places/fuel_match.dart';

/// 3.55 bike type: decides the bike's shape (silhouette) in the garage and on the ride map.
/// The wire id ([name]) is what the gateway keeps on the rider record (`vehicleKind`).
/// Pure Dart (no Flutter), unit tested.
enum BikeType {
  commuter('Commuter', 'Everyday bike: Splendor, Shine, Pulsar'),
  scooter('Scooter', 'Step-through: Activa, Jupiter, Access'),
  sport('Sport', 'Faired or naked sport: R15, Duke, Apache'),
  cruiser('Cruiser', 'Low seat, forward pegs: Meteor, Avenger'),
  adventure('Adventure / Tourer', 'Tall, long travel: Himalayan, GS, Xpulse 200T'),
  offroad('Off-road / Dirt', 'Dirt and trail: Xpulse, CRF, EXC'),
  electric('Electric', 'Electric scooter or bike: Ather, Ola, Chetak'),
  retro('Cafe racer / Retro', 'Classic look: Classic 350, Interceptor, Jawa');

  const BikeType(this.label, this.hint);

  /// What the rider sees ("Cafe racer / Retro").
  final String label;

  /// One line with examples, under the type picker.
  final String hint;

  /// The id sent to the gateway (`vehicleKind`).
  String get wire => name;

  /// The type for a stored / received id, or null when unknown ('' from older apps).
  static BikeType? parse(Object? raw) {
    final s = raw?.toString().trim().toLowerCase() ?? '';
    if (s.isEmpty) return null;
    for (final t in BikeType.values) {
      if (t.name == s) return t;
    }
    return null;
  }
}

/// Guesses the bike type from what the rider typed (make, model, name), so the type picker is
/// pre-selected and the rider only confirms. Null when nothing obvious matches.
class BikeTypeInference {
  BikeTypeInference._();

  /// Keyword → type, checked in order (the first match wins, so more specific words come first:
  /// "Himalayan" before "Royal Enfield", "Xpulse 200T" before "Xpulse"). Words are matched as
  /// whole words or word starts on the lower-cased, space-separated text.
  static const List<(String, BikeType)> _rules = [
    // Electric first: an "Ola S1" or "Chetak" is electric whatever else matches.
    ('ather', BikeType.electric), ('ola s1', BikeType.electric), ('ola roadster', BikeType.electric), ('ola', BikeType.electric),
    ('chetak', BikeType.electric), ('iqube', BikeType.electric), ('vida', BikeType.electric), ('revolt', BikeType.electric),
    ('ultraviolette', BikeType.electric), ('f77', BikeType.electric), ('simple one', BikeType.electric), ('okinawa', BikeType.electric),
    ('ampere', BikeType.electric), ('tork', BikeType.electric), ('oben', BikeType.electric), ('electric', BikeType.electric),
    ('ev', BikeType.electric),
    // Adventure / tourer.
    ('himalayan', BikeType.adventure), ('xpulse 200t', BikeType.adventure), ('adventure', BikeType.adventure), ('adv', BikeType.adventure),
    ('gs', BikeType.adventure), ('tiger', BikeType.adventure), ('africa twin', BikeType.adventure), ('v-strom', BikeType.adventure),
    ('vstrom', BikeType.adventure), ('tenere', BikeType.adventure), ('multistrada', BikeType.adventure), ('versys', BikeType.adventure),
    ('scram', BikeType.adventure), ('dominar', BikeType.adventure), ('tourer', BikeType.adventure), ('rally', BikeType.adventure),
    ('cb500x', BikeType.adventure), ('nx500', BikeType.adventure), ('g 310 gs', BikeType.adventure),
    // Off-road / dirt.
    ('xpulse', BikeType.offroad), ('crf', BikeType.offroad), ('exc', BikeType.offroad), ('wr', BikeType.offroad), ('rmz', BikeType.offroad),
    ('kx', BikeType.offroad), ('yz', BikeType.offroad), ('dirt', BikeType.offroad), ('enduro', BikeType.offroad), ('impulse', BikeType.offroad),
    ('motocross', BikeType.offroad), ('trail', BikeType.offroad),
    // Cruiser.
    ('meteor', BikeType.cruiser), ('avenger', BikeType.cruiser), ('super meteor', BikeType.cruiser), ('thunderbird', BikeType.cruiser),
    ('rebel', BikeType.cruiser), ('eliminator', BikeType.cruiser), ('harley', BikeType.cruiser), ('x440', BikeType.cruiser),
    ('perak', BikeType.cruiser), ('42 bobber', BikeType.cruiser), ('bobber', BikeType.cruiser), ('cruiser', BikeType.cruiser),
    ('shotgun', BikeType.cruiser), ('intruder', BikeType.cruiser), ('vulcan', BikeType.cruiser), ('fat boy', BikeType.cruiser),
    // Retro / cafe racer.
    ('classic', BikeType.retro), ('bullet', BikeType.retro), ('interceptor', BikeType.retro), ('continental', BikeType.retro),
    ('hunter', BikeType.retro), ('jawa', BikeType.retro), ('yezdi roadster', BikeType.retro), ('cafe', BikeType.retro),
    ('retro', BikeType.retro), ('hness', BikeType.retro), ('h ness', BikeType.retro), ('cb350', BikeType.retro), ('speed 400', BikeType.retro),
    ('scrambler', BikeType.retro), ('bonneville', BikeType.retro), ('xsr', BikeType.retro), ('ronin', BikeType.retro),
    ('electra', BikeType.retro), ('standard', BikeType.retro), ('goan classic', BikeType.retro), ('bear 650', BikeType.retro),
    // Scooter (after electric).
    ('activa', BikeType.scooter), ('jupiter', BikeType.scooter), ('access', BikeType.scooter), ('dio', BikeType.scooter),
    ('ntorq', BikeType.scooter), ('fascino', BikeType.scooter), ('ray', BikeType.scooter), ('aerox', BikeType.scooter),
    ('pleasure', BikeType.scooter), ('maestro', BikeType.scooter), ('destini', BikeType.scooter), ('burgman', BikeType.scooter),
    ('avenis', BikeType.scooter), ('vespa', BikeType.scooter), ('aprilia sr', BikeType.scooter), ('sr 125', BikeType.scooter),
    ('sr 160', BikeType.scooter), ('grazia', BikeType.scooter), ('pep', BikeType.scooter), ('zest', BikeType.scooter),
    ('xoom', BikeType.scooter), ('scooty', BikeType.scooter), ('scooter', BikeType.scooter), ('vx', BikeType.scooter),
    ('nmax', BikeType.scooter), ('xmax', BikeType.scooter),
    // Sport.
    ('r15', BikeType.sport), ('r3', BikeType.sport), ('r1', BikeType.sport), ('mt-15', BikeType.sport), ('mt15', BikeType.sport),
    ('mt-03', BikeType.sport), ('duke', BikeType.sport), ('rc', BikeType.sport), ('ninja', BikeType.sport), ('gixxer', BikeType.sport),
    ('apache rr', BikeType.sport), ('rr 310', BikeType.sport), ('rtr', BikeType.sport), ('apache', BikeType.sport),
    ('pulsar ns', BikeType.sport), ('pulsar rs', BikeType.sport), ('ns200', BikeType.sport), ('ns160', BikeType.sport),
    ('n250', BikeType.sport), ('cbr', BikeType.sport), ('fz', BikeType.sport), ('karizma', BikeType.sport), ('xtreme', BikeType.sport),
    ('hornet', BikeType.sport), ('z900', BikeType.sport), ('street triple', BikeType.sport), ('daytona', BikeType.sport),
    ('panigale', BikeType.sport), ('s 1000', BikeType.sport), ('sport', BikeType.sport), ('raider', BikeType.sport), ('mavrick', BikeType.sport),
    // Commuter (last: the everyday names).
    ('splendor', BikeType.commuter), ('passion', BikeType.commuter), ('glamour', BikeType.commuter), ('hf deluxe', BikeType.commuter),
    ('super splendor', BikeType.commuter), ('shine', BikeType.commuter), ('sp 125', BikeType.commuter), ('unicorn', BikeType.commuter),
    ('livo', BikeType.commuter), ('platina', BikeType.commuter), ('ct 100', BikeType.commuter), ('ct100', BikeType.commuter),
    ('discover', BikeType.commuter), ('pulsar', BikeType.commuter), ('star city', BikeType.commuter), ('radeon', BikeType.commuter),
    ('sport 100', BikeType.commuter), ('saluto', BikeType.commuter), ('freedom', BikeType.commuter), ('xblade', BikeType.commuter),
    ('commuter', BikeType.commuter), ('hero', BikeType.commuter), ('honda cd', BikeType.commuter),
  ];

  /// Lower-cased, punctuation as spaces, one space between words, padded with spaces.
  static String _norm(String s) =>
      ' ${s.toLowerCase().replaceAll(RegExp(r"[^a-z0-9\- ]"), ' ').replaceAll(RegExp(r'\s+'), ' ').trim()} ';

  /// The type the words suggest, else (with [fuelType] electric) [BikeType.electric], else null.
  /// [make], [model] and [name] are searched together (model words count most: tried first).
  static BikeType? infer({String make = '', String model = '', String name = '', BikeFuelType? fuelType}) {
    if (fuelType == BikeFuelType.ev) return BikeType.electric;
    for (final text in [_norm('$make $model'), _norm(name)]) {
      if (text.trim().isEmpty) continue;
      for (final (word, type) in _rules) {
        // Whole word or word start ("r15" in "r15 v4", "duke" in "duke390" is not split, so
        // also match a word that starts with the keyword followed by digits).
        if (text.contains(' $word ') || RegExp(' ${RegExp.escape(word)}[0-9]').hasMatch(text)) return type;
      }
    }
    return null;
  }

  /// The type to show when the rider has not picked one: the guess, else a careful default by
  /// engine size (no engine = electric, under 125 cc commuter, otherwise commuter as well, since
  /// a wrong "sport" shape is worse than a plain one).
  static BikeType fallback({String make = '', String model = '', String name = '', BikeFuelType? fuelType, int engineCc = 0}) =>
      infer(make: make, model: model, name: name, fuelType: fuelType) ?? BikeType.commuter;
}
