 'use strict';
const DEFAULTS = Object.freeze({ essentialsEnabled: true, autoDiscovery: true, groupFuelEnabled: true,
  guardianEnabled: true, guardianRequirePin: false, guardianMaxHours: 72,
  notificationInsights: true, guardianStopMinutes: 15, guardianOfflineMinutes: 10,
  guardianDeviationMinutes: 5 });
const LIMITS = { guardianMaxHours: [1, 336], guardianStopMinutes: [5, 120],
  guardianOfflineMinutes: [2, 60], guardianDeviationMinutes: [1, 30] };
function featurePolicy(raw) {
  const out = { ...DEFAULTS };
  for (const key of Object.keys(DEFAULTS)) {
    const value = raw?.[key];
    if (typeof DEFAULTS[key] === 'boolean' && typeof value === 'boolean') out[key] = value;
    if (LIMITS[key] && Number.isInteger(value) && value >= LIMITS[key][0] && value <= LIMITS[key][1]) out[key] = value;
  }
  return out;
}
function policyPatch(current, patch) {
  if (!patch || typeof patch !== 'object' || Array.isArray(patch)) throw new Error('Invalid feature settings.');
  for (const [key, value] of Object.entries(patch)) {
    if (!Object.hasOwn(DEFAULTS, key) || (LIMITS[key] ? !Number.isInteger(value) || value < LIMITS[key][0] || value > LIMITS[key][1]
      : typeof value !== 'boolean')) throw new Error('Invalid feature setting: ' + key);
  }
  return featurePolicy({ ...featurePolicy(current), ...patch });
}
function roomAnalytics(room, now = Date.now()) {
  const riders = [...room.riders.values()];
  const fresh = riders.filter(r => Number.isFinite(r.lastSeenEpochMs) && r.lastSeenEpochMs <= now && now - r.lastSeenEpochMs < 120000);
  const fuel = fresh.filter(r => Number.isFinite(r.fuelEstimate?.usableKm) && Number.isFinite(r.fuelEstimate?.updatedAt) && r.fuelEstimate.updatedAt <= now && now - r.fuelEstimate.updatedAt < 120000);
  return { generatedAt: now, scope: 'current_ride', features: {
    connectivity: { riders: riders.length, fresh: fresh.length, stale: riders.length - fresh.length },
    fuel: { enabled: featurePolicy(room.meta.featurePolicy).groupFuelEnabled, sharingFresh: fuel.length, unavailable: riders.length - fuel.length },
    safety: { activeAlerts: [...room.alerts.values()].filter(a => !a.resolved).length },
    stops: { total: (room.meta.stopPoints || []).length,
      suggested: (room.meta.stopPoints || []).filter(s => s.status === 'SUGGESTED').length },
    essentials: { enabled: featurePolicy(room.meta.featurePolicy).essentialsEnabled, automaticRefresh: featurePolicy(room.meta.featurePolicy).autoDiscovery },
    guardian: { enabled: featurePolicy(room.meta.featurePolicy).guardianEnabled, maximumHours: featurePolicy(room.meta.featurePolicy).guardianMaxHours, pinRequired: featurePolicy(room.meta.featurePolicy).guardianRequirePin, stoppedMinutes: featurePolicy(room.meta.featurePolicy).guardianStopMinutes, offlineMinutes: featurePolicy(room.meta.featurePolicy).guardianOfflineMinutes, deviationMinutes: featurePolicy(room.meta.featurePolicy).guardianDeviationMinutes },
    notifications: { insightsAllowed: featurePolicy(room.meta.featurePolicy).notificationInsights, delivery: 'Device dependent; not measured' },
    power: { lowBattery: fresh.filter(r => Number.isFinite(r.batteryLevel) && r.batteryLevel >= 0 && r.batteryLevel <= 15).length, savings: 'Not measured' },
    route: { calculated: !!room.meta.route && !room.meta.route.approximate },
  } };
}
module.exports = { DEFAULTS, featurePolicy, policyPatch, roomAnalytics };
