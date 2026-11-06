'use strict';
/**
 * Worker thread for legacy bcrypt verification (see password_hash.js). bcryptjs is pure JavaScript and
 * takes 100-300 ms per compare at cost 10-12: here it blocks only this worker, never the gateway's event loop.
 */
const { parentPort } = require('worker_threads');
const bcrypt = require('bcryptjs');

parentPort.on('message', ({ id, password, hash }) => {
  try {
    parentPort.postMessage({ id, ok: bcrypt.compareSync(String(password), String(hash)) === true });
  } catch (e) {
    parentPort.postMessage({ id, ok: false, error: e && e.message ? e.message : 'bcrypt failed' });
  }
});
