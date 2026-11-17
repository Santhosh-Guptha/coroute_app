'use strict';
/**
 * v3.63 rich invite cards (WhatsApp / Telegram / iMessage / X previews): server-rendered Open Graph + Twitter tags on
 * the invite pages, so a shared link shows a branded card instead of a bare URL.
 *
 *   /join/<CODE>         ride invite. A valid active ride code shows "Join Anu's ride: Nandi Hills" with the date,
 *                        riders so far and the destination. Only these facts ever reach a crawler: the host's FIRST
 *                        name, the ride name, the destination name, the day / time and the rider count. Never the
 *                        start place, positions, other riders' names, phone numbers or anything else.
 *                        An unknown / ended code gets the generic ride card (no "this code exists" signal beyond it).
 *   /join/friend/<CODE>  friend invite: a generic card (the page never says whose code it is; neither does the card).
 *
 * Images: static branded 1200x630 PNGs under public/assets/og/ (ride.png, friend.png), made once with Chromium
 * (gateway/tool/og/render_invite_cards.js from tool/og/invite_card_source.html). The dynamic text lives in og:title / og:description.
 */
const OG_W = 1200, OG_H = 630;
const IST_MS = 330 * 60000;

const esc = (s) => String(s == null ? '' : s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
/** Plain one-line text, no control characters, at most `n` characters. */
const clean = (s, n) => {
  const t = String(s == null ? '' : s).replace(/[\u0000-\u001f\u007f\u2028\u2029]+/g, ' ').replace(/\s+/g, ' ').trim();
  return t.length > n ? `${t.slice(0, n - 1).trim()}…` : t;
};
const firstName = (full) => clean(String(full || '').trim().split(/\s+/)[0] || '', 24);

/** "Sat 22 Nov, 6:30 am" in India time. */
function whenText(ms) {
  if (!Number.isFinite(ms) || ms <= 0) return '';
  const d = new Date(ms + IST_MS);
  const days = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  let h = d.getUTCHours(); const m = d.getUTCMinutes(); const ap = h >= 12 ? 'pm' : 'am';
  h = h % 12 || 12;
  return `${days[d.getUTCDay()]} ${d.getUTCDate()} ${months[d.getUTCMonth()]}, ${h}:${String(m).padStart(2, '0')} ${ap}`;
}

/**
 * The few public facts of an active ride for its invite card, or null. Live room first (no database read), then the
 * stored ride, with a short wait so a slow database never holds up the page.
 */
async function rideInviteFacts({ convoys = null, repo = null }, code, { waitMs = 800 } = {}) {
  if (!/^[A-Z0-9]{4,10}$/.test(String(code || ''))) return null;
  let meta = null, riders = 0;
  try {
    for (const room of (convoys && convoys.rooms ? convoys.rooms.values() : [])) {
      if (room && room.meta && room.meta.joinCode === code && ['PLANNING', 'STARTED', 'PAUSED'].includes(room.meta.tripStatus)) {
        meta = room.meta; riders = room.riders ? room.riders.size : 0; break;
      }
    }
    if (!meta && repo && typeof repo.getActiveConvoyByJoinCode === 'function') {
      let t;
      meta = await Promise.race([
        repo.getActiveConvoyByJoinCode(code).catch(() => null),
        new Promise((r) => { t = setTimeout(() => r(null), waitMs); if (t.unref) t.unref(); }),
      ]).finally(() => clearTimeout(t));
    }
  } catch { meta = null; }
  if (!meta) return null;
  return {
    host: firstName(meta.createdByUserName || meta.hostName || ''),
    ride: clean(meta.name, 60),
    destination: clean(meta.destinationName, 60),
    startsAt: Number(meta.plannedStartEpochMs || meta.startTimeEpochMs || meta.createdAtEpochMs) || 0,
    riders,
  };
}

/** Title / description / image for a card (`kind`: 'ride' | 'friend'). */
function inviteMeta(kind, facts, origin, path, { assetHash = null } = {}) {
  const o = String(origin || '').replace(/\/+$/, '');
  // Static assets carry their content hash (?v=), like every /assets reference the site renders (pages.js).
  const img = (rel) => { const h = typeof assetHash === 'function' ? assetHash(rel) : null; return `${o}/assets/${rel}${h ? `?v=${h}` : ''}`; };
  if (kind === 'ride' && facts) {
    const who = facts.host ? `${facts.host}'s ride` : 'a group ride';
    const what = facts.destination || facts.ride;
    const title = clean(`Join ${who}${what ? `: ${what}` : ''}`, 90);
    const bits = [
      facts.ride && facts.destination && facts.ride !== facts.destination ? facts.ride : '',
      whenText(facts.startsAt),
      facts.riders > 0 ? `${facts.riders} ${facts.riders === 1 ? 'rider' : 'riders'} so far` : '',
      'Tap to open CoRoute. Live group map, SOS and crash alerts for everyone.',
    ].filter(Boolean);
    return { title, description: clean(bits.join(' · '), 200), image: img('og/ride.png'), alt: 'CoRoute group ride invite', url: `${o}${path}` };
  }
  if (kind === 'friend') {
    return { title: 'You have a riding friend invite on CoRoute', description: 'Add your friend, plan rides together and keep each other safe with SOS and crash alerts.',
      image: img('og/friend.png'), alt: 'CoRoute friend invite', url: `${o}${path}` };
  }
  return { title: 'Join a group ride on CoRoute', description: 'Live group map, push-to-talk, SOS and crash alerts for every rider. Tap to open CoRoute.',
    image: img('og/ride.png'), alt: 'CoRoute group ride invite', url: `${o}${path}` };
}

/** The tags for <head> (escaped). */
function ogTags(m) {
  return [
    '<meta property="og:type" content="website">',
    '<meta property="og:site_name" content="CoRoute">',
    `<meta property="og:title" content="${esc(m.title)}">`,
    `<meta property="og:description" content="${esc(m.description)}">`,
    `<meta property="og:url" content="${esc(m.url)}">`,
    `<meta property="og:image" content="${esc(m.image)}">`,
    `<meta property="og:image:width" content="${OG_W}">`,
    `<meta property="og:image:height" content="${OG_H}">`,
    `<meta property="og:image:alt" content="${esc(m.alt)}">`,
    '<meta name="twitter:card" content="summary_large_image">',
    `<meta name="twitter:title" content="${esc(m.title)}">`,
    `<meta name="twitter:description" content="${esc(m.description)}">`,
    `<meta name="twitter:image" content="${esc(m.image)}">`,
  ].join('\n');
}

module.exports = { rideInviteFacts, inviteMeta, ogTags, whenText, esc, clean, firstName };
