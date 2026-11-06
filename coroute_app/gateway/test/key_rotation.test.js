'use strict';
/**
 * Secret rotation without collateral damage:
 *  - JWT_SECRET_PREVIOUS: tokens signed with it are accepted (verification only) and refreshed to JWT_SECRET.
 *  - SETTINGS_ENCRYPTION_KEY: admin-saved Razorpay secrets are encrypted with it; legacy (JWT-derived) values
 *    are still read and re-encrypted, so a later JWT_SECRET change no longer loses them.
 *  - Web-checkout links are signed with a SETTINGS_ENCRYPTION_KEY-derived key; links signed before stay valid.
 */
process.env.NODE_ENV = 'test';
process.env.JWT_SECRET_PREVIOUS = 'previous-secret-previous-secret-previous-0001';
process.env.SETTINGS_ENCRYPTION_KEY = Buffer.alloc(32, 7).toString('base64');
const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('crypto');
const jwt = require('jsonwebtoken');
const config = require('../src/config');
const { boot } = require('./_helpers');
const { verifyToken, verifyTokenDetailed } = require('../src/auth');
const { createRazorpayGateway, _settingsCrypto } = require('../src/razorpay_gateway');
const { webCheckoutToken, webCheckoutTokenValid } = require('../src/subscription_routes');
const { Repo } = require('../src/oracle/repo');
const { MemorySoda } = require('../src/oracle/memory_soda');

const sign = (claims, secret, opts = {}) => jwt.sign(claims, secret, { expiresIn: '30d', issuer: 'coroute-gateway', algorithm: 'HS256', ...opts });

test('config: SETTINGS_ENCRYPTION_KEY is 32 bytes; JWT_SECRET_PREVIOUS is loaded', () => {
  assert.equal(config.settingsEncryptionKey.length, 32);
  assert.equal(config.jwtSecretPrevious, process.env.JWT_SECRET_PREVIOUS);
});

test('JWT_SECRET_PREVIOUS: accepted for verification only, and the response moves the client to the new secret', async (t) => {
  const env = await boot();
  t.after(() => env.gw.shutdown());
  const u = await env.register('Rotate Rider', 'rotate@coroute.test');
  const claims = jwt.decode(u.token);
  assert.ok(jwt.verify(u.token, config.jwtSecret), 'new tokens are signed with JWT_SECRET');
  assert.throws(() => jwt.verify(u.token, config.jwtSecretPrevious));

  const old = sign({ sub: claims.sub, name: claims.name, role: claims.role, email: claims.email, pv: claims.pv }, config.jwtSecretPrevious);
  assert.equal(verifyTokenDetailed(old).previous, true);
  const me = await env.api('GET', '/me', null, old);
  assert.equal(me.status, 200);
  const fresh = me.headers.get('x-coroute-token');
  assert.ok(fresh, 'refreshed token header');
  assert.equal(jwt.verify(fresh, config.jwtSecret).sub, claims.sub);
  assert.equal(verifyTokenDetailed(fresh).previous, false);
  // Any authenticated route refreshes, not only /me.
  const trips = await env.api('GET', '/trips', null, old);
  assert.ok(trips.headers.get('x-coroute-token'));
  // A current token gets no refresh header.
  assert.equal((await env.api('GET', '/me', null, u.token)).headers.get('x-coroute-token'), null);

  // Unknown secret, expired token under the previous secret, other algorithm: refused.
  assert.equal((await env.api('GET', '/me', null, sign({ sub: claims.sub }, 'some-other-secret-some-other-secret-0001'))).status, 401);
  assert.equal((await env.api('GET', '/me', null, sign({ sub: claims.sub }, config.jwtSecretPrevious, { expiresIn: -10 }))).status, 401);
  assert.equal(verifyToken(sign({ sub: claims.sub }, config.jwtSecretPrevious, { algorithm: 'HS512' })), null);
});

test('Razorpay settings: legacy JWT-derived values are read, re-encrypted with SETTINGS_ENCRYPTION_KEY, and survive a JWT_SECRET change', async () => {
  const repo = new Repo(new MemorySoda());
  await repo.migrate();
  // Saved by an older gateway: v1 blobs under the JWT-derived key (current and previous JWT secret).
  const legacyEncrypt = (plain, secret) => {
    const iv = crypto.randomBytes(12);
    const c = crypto.createCipheriv('aes-256-gcm', _settingsCrypto.legacyKey(secret), iv);
    const data = Buffer.concat([c.update(plain, 'utf8'), c.final()]);
    return ['v1', iv.toString('base64'), c.getAuthTag().toString('base64'), data.toString('base64')].join(':');
  };
  await repo.setPaymentGatewaySettings({
    mode: 'test', paymentsEnabled: true,
    test: { keyId: 'rzp_test_ABC', keySecretEnc: legacyEncrypt('test-secret-1', config.jwtSecret), webhookSecretEnc: legacyEncrypt('hook-1', config.jwtSecretPrevious) },
    live: {},
  });
  const gw = createRazorpayGateway({ repo });
  const s = await gw.settings({ fresh: true });
  assert.equal(s.test.keySecret, 'test-secret-1');
  assert.equal(s.test.webhookSecret, 'hook-1', 'readable with JWT_SECRET_PREVIOUS during a rotation');

  const saved = await repo.getPaymentGatewaySettings();
  assert.ok(saved.test.keySecretEnc.startsWith('v2:'), 'migrated');
  assert.ok(saved.test.webhookSecretEnc.startsWith('v2:'));
  assert.equal(saved.test.keyId, 'rzp_test_ABC');
  assert.equal(_settingsCrypto.decryptDetailed(saved.test.keySecretEnc).stale, false);

  // JWT_SECRET rotated (and the previous one dropped): the migrated secrets are still there.
  const jwtSecret = config.jwtSecret; const previous = config.jwtSecretPrevious;
  config.jwtSecret = 'rotated-secret-rotated-secret-rotated-0002'; config.jwtSecretPrevious = '';
  try {
    const after = await createRazorpayGateway({ repo }).settings({ fresh: true });
    assert.equal(after.test.keySecret, 'test-secret-1');
    assert.equal(after.test.webhookSecret, 'hook-1');
    // New saves use the settings key too.
    assert.ok(_settingsCrypto.encrypt('x').startsWith('v2:'));
  } finally { config.jwtSecret = jwtSecret; config.jwtSecretPrevious = previous; }

  // A value saved under a key this server does not have reads as "not set" (never throws).
  assert.equal(_settingsCrypto.decrypt(legacyEncrypt('lost', 'unknown-secret-unknown-secret-unknown-1')), '');
});

test('web checkout links: signed with the SETTINGS_ENCRYPTION_KEY-derived key; links signed before stay valid', () => {
  const exp = Date.now() + 600000;
  const t = webCheckoutToken('order_1', exp);
  assert.match(t, /^[0-9a-f]{32}$/);
  assert.ok(webCheckoutTokenValid('order_1', exp, t));
  const legacy = crypto.createHmac('sha256', config.jwtSecret).update(`web-checkout:order_1:${exp}`).digest('hex').slice(0, 32);
  assert.notEqual(t, legacy, 'no longer signed with JWT_SECRET');
  assert.ok(webCheckoutTokenValid('order_1', exp, legacy), 'links signed before still open');
  const legacyPrev = crypto.createHmac('sha256', config.jwtSecretPrevious).update(`web-checkout:order_1:${exp}`).digest('hex').slice(0, 32);
  assert.ok(webCheckoutTokenValid('order_1', exp, legacyPrev));
  assert.equal(webCheckoutTokenValid('order_2', exp, t), false);
  assert.equal(webCheckoutTokenValid('order_1', exp + 1, t), false);
  assert.equal(webCheckoutTokenValid('order_1', exp, ''), false);
  // Rotating JWT_SECRET does not invalidate new links.
  const jwtSecret = config.jwtSecret;
  config.jwtSecret = 'rotated-secret-rotated-secret-rotated-0002';
  try { assert.ok(webCheckoutTokenValid('order_1', exp, t)); } finally { config.jwtSecret = jwtSecret; }
});
