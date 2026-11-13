'use strict';
/**
 * Creates load-test riders and convoys inside a running gateway process (createApp result), without the
 * HTTP API (no password hashing, no rate limits): users get a random unusable password hash, an app session
 * and a token; every group's first rider creates the convoy and the others join by code.
 * Used by ws_load.js (local, MemorySoda) and seed_staging.js (staging database only).
 */
const crypto = require('crypto');

async function seedRiders(gw, { riders = 100, groupSize = 8, prefix = 'load', emailDomain = 'load.invalid' } = {}) {
  const out = [];
  const tag = crypto.randomBytes(3).toString('hex');
  let convoy = null;
  for (let i = 0; i < riders; i++) {
    const n = String(i).padStart(5, '0');
    const user = await gw.repo.createUser({
      userId: `usr_${prefix}${tag}${n}`, name: `${prefix}${tag}${n}`, email: `${prefix}+${tag}${n}@${emailDomain}`,
      passwordHash: `x$${crypto.randomBytes(16).toString('hex')}`, role: 'RIDER', provider: 'password',
      phone: `+9190${String(10000000 + i).slice(-8)}`, vehicleType: 'Motorcycle', vehicleNo: `KA01LT${String(1000 + (i % 9000)).slice(-4)}`,
      emergencyContact: '+919000000001', emergencyContactName: 'ICE', createdAt: Date.now(), lastLoginAt: Date.now(),
      emailVerified: true, loadTest: true,
    });
    const issued = await gw.auth._issue(user, { client: 'app', created: true, ip: '127.0.0.1', ua: 'coroute-load' });
    const ident = { userId: user.userId, name: user.name, role: user.role, email: user.email };
    if (i % groupSize === 0) {
      convoy = await gw.convoys.createConvoy(ident, { name: `Load ${tag} ${i / groupSize}` });
    } else {
      await gw.convoys.joinByCode(ident, convoy.joinCode);
    }
    out.push({ userId: user.userId, token: issued.token, groupId: convoy.groupId });
  }
  return out;
}

module.exports = { seedRiders };
