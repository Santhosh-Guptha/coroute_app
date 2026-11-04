const { createSoda } = require('../src/app');
const { Repo } = require('../src/oracle/repo');

async function run() {
  try {
    const soda = createSoda();
    const repo = new Repo(soda);
    const result = await repo.reconcileDuplicateMembershipsAndOrders();
    console.log('RECONCILIATION_RESULT:', JSON.stringify(result, null, 2));
    process.exit(0);
  } catch (err) {
    console.error('Reconciliation error:', err);
    process.exit(1);
  }
}

run();
