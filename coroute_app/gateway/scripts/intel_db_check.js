'use strict';
// v3.62b readiness check for the intelligence database (DB 2), run on a VM BEFORE turning on INTEL_DB_MIGRATE:
//   cd gateway && node scripts/intel_db_check.js
// Reads INTEL_SODA_URL / INTEL_ORACLE_USER / INTEL_ORACLE_PASSWORD from the same .env as the gateway. Checks that
// DB 2 answers, that the credentials work, that it can create a collection, write, read and delete a test document,
// that it is a DIFFERENT database from the main one, and the round-trip times. Prints no secrets and changes no data
// (the test collection `intel_db_check` is removed again). Exit code 0 = ready.
const config = require('../src/config');
const { createSoda, createIntelSoda } = require('../src/app');
const IS = require('../src/oracle/intel_store');

const ms = async (fn) => { const t = process.hrtime.bigint(); const v = await fn(); return [v, Number(process.hrtime.bigint() - t) / 1e6]; };
const host = (u) => { try { return new URL(u).host.replace(/^[^.]+/, '***'); } catch { return '(not a URL)'; } };

(async () => {
  if (!config.intelSodaUrl) { console.log('INTEL_SODA_URL is not set: intelligence stays in the main database. Nothing to check.'); process.exit(2); }
  if (config.intelSodaUrl === config.sodaUrl) { console.error('FAIL: INTEL_SODA_URL is the same as ORACLE_SODA_URL. DB 2 must be a different database.'); process.exit(1); }
  const intel = createIntelSoda();
  const main = createSoda();
  console.log(`DB 2 host: ${host(config.intelSodaUrl)} (main: ${host(config.sodaUrl)})`);
  const [up, pingMs] = await ms(() => intel.ping());
  if (!up) { console.error('FAIL: DB 2 is not reachable or rejected the user / password.'); process.exit(1); }
  console.log(`OK  reachable, credentials accepted (${pingMs.toFixed(0)} ms)`);
  const C = 'intel_db_check';
  await intel.ensureCollection(C);
  const [k, wMs] = await ms(() => intel.insert(C, { k: 'probe', at: Date.now() }));
  const [row, rMs] = await ms(() => intel.findOne(C, { k: 'probe' }));
  if (!row) { console.error('FAIL: wrote a test document but could not read it back.'); process.exit(1); }
  await intel.remove(C, k);
  if (typeof intel.dropCollection === 'function') await intel.dropCollection(C).catch(() => {});
  console.log(`OK  write ${wMs.toFixed(0)} ms, read ${rMs.toFixed(0)} ms, delete done`);
  const [, mainMs] = await ms(() => main.ping());
  console.log(`OK  main database answers (${mainMs.toFixed(0)} ms)`);
  const cols = [...IS.intelCollections()];
  console.log(`Collections that will move (${process.env.INTEL_DB_PROFILE === 'extended' ? 'extended profile' : 'default profile'}): ${cols.join(', ')}`);
  console.log('Safety data (accounts, rides, SOS, sessions, guardians, payments) always stays in the main database.');
  console.log('READY: set INTEL_SODA_URL (+ user / password) on BOTH VMs, restart, then INTEL_DB_MIGRATE=1 on ONE VM.');
})().catch((e) => { console.error(`FAIL: ${e.message}`); process.exit(1); });
