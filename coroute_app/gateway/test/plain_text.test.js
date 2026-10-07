'use strict';
process.env.NODE_ENV = 'test';

const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const { WAIT_MESSAGE } = require('../src/convoys');
const { boot } = require('./_helpers');

let t;
before(async () => { t = await boot(); });
after(async () => { await t.gw.shutdown(); });

/** Characters above U+2000 that are not ordinary punctuation (emoji, symbols, dashes). */
const unusual = (s) => [...s].filter((ch) => ch.codePointAt(0) > 0x2000 && !'‘’“”…'.includes(ch));

test('the "wait for me" card is plain text and reaches the convoy', async () => {
  assert.deepEqual(unusual(WAIT_MESSAGE), []);
  const lead = await t.register('Plain Lead', 'plainlead@coroute.test');
  const c = (await t.api('POST', '/convoys', { name: 'Plain ride' }, lead.token)).json;
  const ws = await t.joinRoom(lead.token, c.groupId);
  ws.sendJson({ type: 'WAIT' });
  const card = await ws.next((m) => m.type === 'MESSAGE' && m.message.cardType === 'WAIT_2MIN');
  assert.equal(card.message.text, WAIT_MESSAGE);
  assert.equal(card.message.senderName, 'Plain Lead');
  assert.deepEqual(unusual(card.message.text), []);
  ws.close();
});
