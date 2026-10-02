'use strict';
// Creates collections and indexes in Oracle. Idempotent. Also run automatically at boot.
const { createSoda } = require('../src/app');
const { Repo } = require('../src/oracle/repo');
(async () => {
  const soda = createSoda();
  console.log('Connecting to', require('../src/config').sodaUrl);
  if (!(await soda.ping())) throw new Error('SODA endpoint not reachable or credentials rejected');
  await new Repo(soda).migrate();
  console.log('Collections:', (await soda.listCollections()).join(', '));
  console.log('Done.');
})().catch((e) => { console.error(e.message, e.body || ''); process.exit(1); });
