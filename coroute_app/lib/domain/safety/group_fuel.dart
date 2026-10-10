/// Only fresh, consented, usable ranges contribute. Raw tank inputs never leave
/// the device. Positions remain necessary before recommending a common stop.
class SharedFuelRange {
  final String riderId;
  final double usableKm;
  final int updatedAt, positionAt;
  const SharedFuelRange(this.riderId, this.usableKm, this.updatedAt, this.positionAt);

  bool freshAt(int now) => usableKm.isFinite && usableKm >= 0 && usableKm <= 15000 &&
      updatedAt > 0 && positionAt > 0 && now >= updatedAt && now >= positionAt &&
      now - updatedAt < 120000 && now - positionAt < 120000;
}

class GroupFuelSummary {
  final int contributors, total;
  final double? lowestKm;
  const GroupFuelSummary(this.contributors, this.total, this.lowestKm);
  static GroupFuelSummary calculate(Iterable<SharedFuelRange> shared, {required int total, required int now}) {
    final byRider = <String, SharedFuelRange>{};
    for (final f in shared) {
      if (f.freshAt(now) && (byRider[f.riderId]?.updatedAt ?? -1) < f.updatedAt) byRider[f.riderId] = f;
    }
    double? lowest;
    for (final f in byRider.values) {
      if (lowest == null || f.usableKm < lowest) lowest = f.usableKm;
    }
    return GroupFuelSummary(byRider.length, total, lowest);
  }
}
