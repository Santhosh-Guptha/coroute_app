'use strict';
/**
 * Password hashes: new ones are scrypt (scrypt$N$r$p$salt$hash) computed on the libuv threadpool; legacy
 * bcrypt hashes are verified in a worker thread and upgraded to scrypt at the next successful sign-in,
 * without ending other sessions. The event loop never runs a hash.
 */
process.env.NODE_ENV = 'test';
const test = require('node:test');
const assert = require('node:assert/strict');
const { monitorEventLoopDelay } = require('node:perf_hooks');
const bcrypt = require('bcryptjs');
const { Repo } = require('../src/oracle/repo');
const { MemorySoda } = require('../src/oracle/memory_soda');
const { AuthService } = require('../src/auth');
const { PasswordHasher, parseScrypt } = require('../src/password_hash');
const config = require('../src/config');

const profile = {
  phone: '+919876500001', vehicleType: 'Motorcycle', vehicleNo: 'TS09AB0001',
  emergencyContact: '+919000000001', emergencyContactName: 'Family Contact',
};

test('production cost is N=2^15, r=8, p=1; the test suite runs cheaper via PASSWORD_SCRYPT_N', () => {
  assert.equal(config.passwordScryptN, 1024, 'NODE_ENV=test');
  const src = require('fs').readFileSync(require.resolve('../src/config'), 'utf8');
  assert.match(src, /passwordScryptN: int\('PASSWORD_SCRYPT_N', isTest \? 1024 : 32768\)/);
  assert.equal(config.passwordScryptR, 8);
  assert.equal(config.passwordScryptP, 1);
});

test('scrypt round trip: format, constant parameters, wrong password, malformed hashes', async () => {
  const h = new PasswordHasher({ N: 1024 });
  const stored = await h.hash('Password#123');
  assert.match(stored, /^scrypt\$1024\$8\$1\$[A-Za-z0-9+/=]+\$[A-Za-z0-9+/=]+$/);
  const parsed = parseScrypt(stored);
  assert.equal(parsed.salt.length, 16);
  assert.equal(parsed.hash.length, 32);
  assert.notEqual(await h.hash('Password#123'), stored, 'random salt');
  assert.deepEqual(await h.verify('Password#123', stored), { ok: true, needsRehash: false, legacy: false });
  assert.equal((await h.verify('Password#124', stored)).ok, false);
  // Hashed at other parameters: valid, flagged for an upgrade.
  const stronger = new PasswordHasher({ N: 2048 });
  assert.deepEqual(await stronger.verify('Password#123', stored), { ok: true, needsRehash: true, legacy: false });
  // Corrupt or hostile values never throw and never pass (a huge N is refused before any work).
  for (const bad of ['', 'scrypt$', 'scrypt$1048577$8$1$AAAA$AAAA', `scrypt$${2 ** 24}$8$1$${'A'.repeat(24)}$${'A'.repeat(44)}`, 'plaintext', '$2b$10$short']) {
    assert.equal((await h.verify('Password#123', bad)).ok, false, bad);
  }
  await h.close();
});

test('legacy bcrypt sign-in is verified in a worker and upgraded to scrypt; a wrong password changes nothing', async () => {
  const repo = new Repo(new MemorySoda());
  await repo.migrate();
  const hasher = new PasswordHasher({ N: 1024 });
  const auth = new AuthService(repo, { hasher });

  const reg = await auth.register({ name: 'Hash Rider', email: 'hash@coroute.test', password: 'Password#123', ...profile });
  assert.ok((await repo.findUserById(reg.user.userId)).passwordHash.startsWith('scrypt$1024$8$1$'));

  // A legacy account hashed with bcrypt cost 10.
  const legacyHash = await bcrypt.hash('Legacy#pass1', 10);
  await repo.createUser({ userId: 'usr_legacy_hash', name: 'Legacy Hash', email: 'legacy.hash@coroute.test', passwordHash: legacyHash, provider: 'password', createdAt: Date.now(), passwordChangedAt: 1234 });

  await assert.rejects(auth.login({ identifier: 'legacy.hash@coroute.test', password: 'wrong-password' }), { status: 401 });
  assert.equal((await repo.findUserById('usr_legacy_hash')).passwordHash, legacyHash, 'a failed sign-in never rewrites the hash');

  const ok = await auth.login({ identifier: 'legacy.hash@coroute.test', password: 'Legacy#pass1' });
  assert.ok(ok.token);
  const after = await repo.findUserById('usr_legacy_hash');
  assert.ok(after.passwordHash.startsWith('scrypt$'), 'upgraded to scrypt');
  assert.ok((await hasher.verify('Legacy#pass1', after.passwordHash)).ok);
  assert.equal(after.passwordChangedAt, 1234, 'other sessions are not ended by the upgrade');

  // Already current: the next sign-in leaves the hash alone.
  await auth.login({ identifier: 'Legacy Hash', password: 'Legacy#pass1' });
  assert.equal((await repo.findUserById('usr_legacy_hash')).passwordHash, after.passwordHash);

  // Password change and admin reset write scrypt too.
  await auth.changePassword('usr_legacy_hash', { currentPassword: 'Legacy#pass1', newPassword: 'Changed#pass2' });
  assert.ok((await repo.findUserById('usr_legacy_hash')).passwordHash.startsWith('scrypt$'));
  await assert.rejects(auth.changePassword('usr_legacy_hash', { currentPassword: 'Legacy#pass1', newPassword: 'Changed#pass3' }), { status: 401 });
  const reset = await auth.adminResetPassword({ userId: 'usr_admin' }, 'usr_legacy_hash');
  assert.ok((await repo.findUserById('usr_legacy_hash')).passwordHash.startsWith('scrypt$'));
  assert.ok(await auth.login({ identifier: 'Legacy Hash', password: reset.temporaryPassword }));

  // An unknown account still costs a verify and is refused the same way.
  await assert.rejects(auth.login({ identifier: 'nobody@coroute.test', password: 'Password#123' }), { status: 401 });
  await hasher.close();
});

test('event loop stays responsive (< 100 ms lag) during 10 concurrent logins at production cost', async () => {
  const repo = new Repo(new MemorySoda());
  await repo.migrate();
  const hasher = new PasswordHasher({ N: 1 << 15, r: 8, p: 1, concurrency: 2 });
  const auth = new AuthService(repo, { hasher });
  // 5 scrypt accounts at production cost, 5 legacy bcrypt accounts at cost 10 (worker thread).
  for (let i = 0; i < 10; i++) {
    const passwordHash = i < 5 ? await hasher.hash(`Password#${i}`) : bcrypt.hashSync(`Password#${i}`, 10);
    await repo.createUser({ userId: `usr_lag_${i}`, name: `Lag Rider ${i}`, email: `lag${i}@coroute.test`, passwordHash, provider: 'password', createdAt: Date.now() });
  }
  // Warm the bcrypt worker so its start-up is not measured.
  await hasher.bcrypt.compare('x', bcrypt.hashSync('y', 4));

  const h = monitorEventLoopDelay({ resolution: 10 });
  h.enable();
  const started = Date.now();
  const results = await Promise.all(Array.from({ length: 10 }, (_, i) => auth.login({ identifier: `lag${i}@coroute.test`, password: `Password#${i}` })));
  h.disable();
  assert.equal(results.length, 10);
  for (const r of results) assert.ok(r.token);
  const maxLagMs = h.max / 1e6;
  assert.ok(maxLagMs < 100, `event loop lag ${maxLagMs.toFixed(1)} ms over ${Date.now() - started} ms`);
  // The five legacy accounts were upgraded.
  for (let i = 5; i < 10; i++) assert.ok((await repo.findUserById(`usr_lag_${i}`)).passwordHash.startsWith('scrypt$32768$8$1$'));
  await hasher.close();
});
