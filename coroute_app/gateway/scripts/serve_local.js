'use strict';
/**
 * Local preview server for CoRoute website.
 * Runs standalone with in-memory persistence and full web rendering.
 */
process.env.NODE_ENV = 'test';
process.env.BOOTSTRAP_ADMIN_EMAILS = 'admin@coroute.test';

const port = parseInt(process.env.PORT, 10) || 3000;
const host = process.env.HOST || '127.0.0.1';

const { createApp } = require('../src/app');
const { MemorySoda } = require('../src/oracle/memory_soda');

(async () => {
  try {
    const soda = new MemorySoda();
    const gw = await createApp({
      soda,
      logger: {
        info: (...a) => console.log(new Date().toISOString(), ...a),
        warn: (...a) => console.warn(new Date().toISOString(), ...a),
        error: (...a) => console.error(new Date().toISOString(), ...a),
      }
    });

    gw.server.listen(port, host, () => {
      console.log(`\n======================================================`);
      console.log(` CoRoute Local Preview Server Running!`);
      console.log(` Website:  http://${host}:${port}/`);
      console.log(` Features: http://${host}:${port}/features`);
      console.log(` Cockpit:  http://${host}:${port}/#cockpit-3d`);
      console.log(`======================================================\n`);
    });

    const stop = async () => {
      console.log('\nShutting down local server...');
      await gw.shutdown();
      process.exit(0);
    };

    process.on('SIGINT', stop);
    process.on('SIGTERM', stop);
  } catch (err) {
    console.error('Failed to start local preview server:', err);
    process.exit(1);
  }
})();
