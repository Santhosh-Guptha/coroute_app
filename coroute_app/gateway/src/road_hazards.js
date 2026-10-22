'use strict';

/**
 * CoRoute Road Hazard Registry (FEAT-02)
 * Manages server-side 100-meter spatial deduplication, multi-rider corroboration,
 * TTL expiry, and downstream route/carriageway recipient matching.
 */

const DEG2RAD = Math.PI / 180;
const EARTH_RADIUS_M = 6371000;

function haversineM(lat1, lon1, lat2, lon2) {
  const dLat = (lat2 - lat1) * DEG2RAD;
  const dLon = (lon2 - lon1) * DEG2RAD;
  const a =
    Math.sin(dLat / 2) * Math.sin(dLat / 2) +
    Math.cos(lat1 * DEG2RAD) * Math.cos(lat2 * DEG2RAD) *
    Math.sin(dLon / 2) * Math.sin(dLon / 2);
  const c = 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
  return EARTH_RADIUS_M * c;
}

function angleDiff(a, b) {
  const d = ((a - b) % 360 + 360) % 360;
  return d > 180 ? 360 - d : d;
}

class RoadHazardRegistry {
  constructor(options = {}) {
    this.deduplicationRadiusM = options.deduplicationRadiusM || 100.0;
    this.directionToleranceDeg = options.directionToleranceDeg || 60.0;
    this.hazardTtlMs = options.hazardTtlMs || 12 * 60 * 60 * 1000; // 12 hours
    this.pins = new Map(); // hazardId -> pin
  }

  /**
   * Ingests a validated hazard observation from a Road Captain.
   * Performs 100m spatial deduplication and returns the active pin record.
   */
  ingestObservation(obs) {
    const now = Date.now();
    this.prune(now);

    const lat = Number(obs.lat);
    const lng = Number(obs.lng);
    const heading = Number(obs.heading) || 0;
    const severity = obs.severity || 'HIGH';
    const classification = obs.classification || 'POTHOLE';
    const confidence = Math.min(1.0, Math.max(0.1, Number(obs.confidence) || 0.85));

    // Check for existing pin within 100m in matching carriageway direction
    let match = null;
    let minD = Infinity;

    for (const pin of this.pins.values()) {
      const d = haversineM(pin.lat, pin.lng, lat, lng);
      if (d <= this.deduplicationRadiusM) {
        if (pin.heading > 0 && heading > 0) {
          if (angleDiff(pin.heading, heading) > this.directionToleranceDeg) {
            // Opposite carriageway on divided highway; keep separate
            continue;
          }
        }
        if (d < minD) {
          minD = d;
          match = pin;
        }
      }
    }

    if (match) {
      // Idempotency: duplicate event ID already ingested
      if (obs.hazardId && match.seenEventIds && match.seenEventIds.has(obs.hazardId)) {
        return { pin: match, isNew: false, duplicate: true };
      }
      if (obs.hazardId && match.seenEventIds) {
        match.seenEventIds.add(obs.hazardId);
      }

      match.lastCorroboratedAt = now;
      if (severity === 'CRITICAL' || (severity === 'HIGH' && match.severity !== 'CRITICAL')) {
        match.severity = severity;
      }

      // Independent rider check: only increment corroboration if reported by a new distinct rider
      const isNewRider = obs.userId && match.contributingRiderIds && !match.contributingRiderIds.has(obs.userId);
      if (isNewRider) {
        match.contributingRiderIds.add(obs.userId);
        match.corroborationCount = (match.corroborationCount || 1) + 1;
        match.confidence = Math.min(1.0, match.confidence + 0.15);
      } else if (!match.contributingRiderIds) {
        match.contributingRiderIds = new Set(obs.userId ? [obs.userId] : []);
        match.corroborationCount = (match.corroborationCount || 1) + 1;
        match.confidence = Math.min(1.0, match.confidence + 0.15);
      }

      return { pin: match, isNew: false, duplicate: false };
    }

    const hazardId = obs.hazardId || `rh_${now}_${Math.floor(Math.random() * 10000)}`;
    const newPin = {
      hazardId,
      lat: Number(lat.toFixed(6)),
      lng: Number(lng.toFixed(6)),
      heading: Number(heading.toFixed(1)),
      severity,
      classification,
      confidence: Number(confidence.toFixed(2)),
      corroborationCount: 1,
      contributingRiderIds: new Set(obs.userId ? [obs.userId] : []),
      seenEventIds: new Set(obs.hazardId ? [obs.hazardId] : []),
      firstDetectedAt: obs.timestamp || now,
      lastCorroboratedAt: now,
      expiresAt: now + this.hazardTtlMs,
      spokenWarning: 'Caution: severe road hazard 300 meters ahead',
    };

    this.pins.set(hazardId, newPin);
    return { pin: newPin, isNew: true, duplicate: false };
  }

  /**
   * Filters connected riders in a room to identify who should receive the broadcast.
   * Excludes:
   * 1. Riders who already passed the hazard.
   * 2. Riders on the opposite carriageway.
   * 3. Riders farther than 5 km away.
   */
  filterEligibleRecipients(pin, roomRiders) {
    const eligible = [];
    if (!roomRiders || !Array.isArray(roomRiders)) return eligible;

    for (const rider of roomRiders) {
      if (!rider || !Number.isFinite(rider.lat) || !Number.isFinite(rider.lng)) continue;

      const d = haversineM(rider.lat, rider.lng, pin.lat, pin.lng);

      // Distance filter: must be within 5000m and not right on top (< 20m)
      if (d < 20 || d > 5000) continue;

      // Carriageway direction filter: if rider heading and pin heading are available,
      // rider must be traveling in roughly the same direction (within 60 degrees)
      if (Number.isFinite(rider.heading) && rider.heading > 0 && pin.heading > 0) {
        const diff = angleDiff(rider.heading, pin.heading);
        if (diff > this.directionToleranceDeg) {
          // Oncoming opposite carriageway; skip
          continue;
        }
      }

      // Bearing check: verify hazard is in front of the rider, not behind
      const bearingToHazard = (Math.atan2(
        Math.sin((pin.lng - rider.lng) * DEG2RAD) * Math.cos(pin.lat * DEG2RAD),
        Math.cos(rider.lat * DEG2RAD) * Math.sin(pin.lat * DEG2RAD) -
          Math.sin(rider.lat * DEG2RAD) * Math.cos(pin.lat * DEG2RAD) * Math.cos((pin.lng - rider.lng) * DEG2RAD)
      ) * 180 / Math.PI + 360) % 360;

      if (Number.isFinite(rider.heading) && rider.heading > 0) {
        const bearingDiff = angleDiff(rider.heading, bearingToHazard);
        if (bearingDiff > 85) {
          // Hazard is behind the rider; rider has already passed!
          continue;
        }
      }

      eligible.push({
        userId: rider.userId,
        distanceM: Math.round(d),
      });
    }

    return eligible;
  }

  prune(now = Date.now()) {
    for (const [id, pin] of this.pins.entries()) {
      if (now > pin.expiresAt) {
        this.pins.delete(id);
      }
    }
  }
}

module.exports = {
  RoadHazardRegistry,
  haversineM,
  angleDiff,
};
