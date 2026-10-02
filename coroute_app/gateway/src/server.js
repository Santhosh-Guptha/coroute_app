'use strict';
const config = require('./config');
const { createApp } = require('./app');

const log = {
  info: (...a) => console.log(new Date().toISOString(), ...a),
  warn: (...a) => console.warn(new Date().toISOString(), ...a),
  error: (...a) => console.error(new Date().toISOString(), ...a),
};

(async () => {
  try {
    const gw = await createApp({ logger: log });
    gw.retention.start();
    gw.server.listen(config.port, config.host, () => {
      log.info(`[CoRoute] gateway v${require('../package.json').version} listening on http://${config.host}:${config.port} (ws at /ws)`);
      log.info(`[CoRoute] Oracle SODA endpoint: ${config.sodaUrl}`);
    });

    const stop = async (sig) => {
      log.info(`[CoRoute] ${sig} received — flushing state and shutting down`);
      try { await gw.shutdown(); } catch (e) { log.error('shutdown error', e); }
      process.exit(0);
    };
    process.on('SIGTERM', () => stop('SIGTERM'));
    process.on('SIGINT', () => stop('SIGINT'));
    process.on('unhandledRejection', (e) => log.error('[CoRoute] unhandledRejection', e));
  } catch (e) {
    log.error('[CoRoute] fatal startup error:', e.message);
    process.exit(1);
  }
})();
