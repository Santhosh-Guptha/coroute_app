'use strict';
/**
 * Password hashes: new ones use bcrypt cost 12 (production setting); a stored hash with a lower cost
 * is re-hashed transparently at the next successful sign-in, without ending other sessions.
 */
process.env.NODE_ENV = 'test';
const test = require('node:test');
const assert = require('node:assert/strict');
const bcrypt = require('bcryptjs');
const { Repo } = require('../src/oracle/repo');
const { MemorySoda } = require('../src/oracle/memory_soda');
const { AuthService } = require('../src/auth');
const config = require('../src/config');

const profile = {
  phone: '+919876500001', vehicleType: 'Motorcycle', vehicleNo: 'TS09AB0001',
  emergencyContact: '+919000000001', emergencyContactName: 'Family Contact',
};

test('production cost is 12; the test suite runs at the minimum', () => {
  assert.equal(config.bcryptCost, 4, 'NODE_ENV=test');
  const src = require('fs').readFileSync(require.resolve('../src/config'), 'utf8');
  assert.match(src, /bcryptCost: isTest \? 4 : 12/);
});

test('new hashes use cost 12; an older cost-10 hash is upgraded at sign-in, a wrong password changes nothing', async () => {
  const repo = new Repo(new MemorySoda());
  await repo.migrate();
  const auth = new AuthService(repo, { bcryptCost: 12 });

  const reg = await auth.register({ name: 'Hash Rider', email: 'hash@coroute.test', password: 'Password#123', ...profile });
  assert.equal(bcrypt.getRounds((await repo.findUserById(reg.user.userId)).passwordHash), 12);

  // A legacy account hashed with cost 10.
  const legacyHash = await bcrypt.hash('Legacy#pass1', 10);
  await repo.createUser({ userId: 'usr_legacy_hash', name: 'Legacy Hash', email: 'legacy.hash@coroute.test', passwordHash: legacyHash, provider: 'password', createdAt: Date.now(), passwordChangedAt: 1234 });

  await assert.rejects(auth.login({ identifier: 'legacy.hash@coroute.test', password: 'wrong-password' }), { status: 401 });
  assert.equal((await repo.findUserById('usr_legacy_hash')).passwordHash, legacyHash, 'a failed sign-in never rewrites the hash');

  const ok = await auth.login({ identifier: 'legacy.hash@coroute.test', password: 'Legacy#pass1' });
  assert.ok(ok.token);
  const after = await repo.findUserById('usr_legacy_hash');
  assert.notEqual(after.passwordHash, legacyHash);
  assert.equal(bcrypt.getRounds(after.passwordHash), 12);
  assert.ok(await bcrypt.compare('Legacy#pass1', after.passwordHash));
  assert.equal(after.passwordChangedAt, 1234, 'other sessions are not ended by the upgrade');

  // Already at cost 12: the next sign-in leaves the hash alone.
  await auth.login({ identifier: 'Legacy Hash', password: 'Legacy#pass1' });
  assert.equal((await repo.findUserById('usr_legacy_hash')).passwordHash, after.passwordHash);

  // Password change and admin reset hash at cost 12 too.
  await auth.changePassword('usr_legacy_hash', { currentPassword: 'Legacy#pass1', newPassword: 'Changed#pass2' });
  assert.equal(bcrypt.getRounds((await repo.findUserById('usr_legacy_hash')).passwordHash), 12);
  await auth.adminResetPassword({ userId: 'usr_admin' }, 'usr_legacy_hash');
  assert.equal(bcrypt.getRounds((await repo.findUserById('usr_legacy_hash')).passwordHash), 12);

  // An unknown account still costs a compare and is refused.
  await assert.rejects(auth.login({ identifier: 'nobody@coroute.test', password: 'Password#123' }), { status: 401 });
});
