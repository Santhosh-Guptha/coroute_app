'use strict';
/**
 * "Suggest a safety feature" from the app (B4): POST /api/feedback with the app's topics
 * (safety-idea, group-riding, map-navigation, other). A signed-in rider may send an idea without
 * an e-mail ("Contact me" off); then nothing about the account is stored. Without a valid token
 * the e-mail stays required, as on the website.
 */
process.env.NODE_ENV = 'test';
const test = require('node:test');
const assert = require('node:assert/strict');
const { boot } = require('./_helpers');

const MSG = 'Warn the group when someone stops for long on a ghat road.';
const old = () => Date.now() - 10000;

test('app ideas: topics, optional e-mail for signed-in riders, contact flag', async (t) => {
  const env = await boot();
  t.after(() => env.gw.shutdown());
  const reg = await env.register('Idea Rider', 'idea.rider@coroute.test');
  const token = reg.token;
  assert.ok(token, 'registered rider has a token');
  const ip = (n) => ({ 'X-Forwarded-For': `198.51.100.${n}` });

  // Contact me off: no e-mail, the token stands in; stored without name or e-mail.
  const anon = await env.api('POST', '/feedback', { name: 'Idea Rider', message: MSG, topic: 'group-riding', t: old(), contact: false, appVersion: '3.54.0+10018' }, token, ip(1));
  assert.equal(anon.status, 201, JSON.stringify(anon.json));

  // Contact me on: the account e-mail goes along.
  const named = await env.api('POST', '/feedback', { name: 'Idea Rider', email: 'idea.rider@coroute.test', message: MSG + ' Please.', topic: 'map-navigation', t: old(), contact: true, appVersion: '3.54.0+10018' }, token, ip(2));
  assert.equal(named.status, 201, JSON.stringify(named.json));

  // No token and no e-mail: refused as before.
  const noAuth = await env.api('POST', '/feedback', { message: MSG, topic: 'safety-idea', t: old() }, null, ip(3));
  assert.equal(noAuth.status, 422);
  assert.ok(noAuth.json.fields.email);

  // A forged token does not stand in for the e-mail.
  const forged = await env.api('POST', '/feedback', { message: MSG, topic: 'safety-idea', t: old() }, 'not-a-real-token', ip(4));
  assert.equal(forged.status, 422);
  assert.ok(forged.json.fields.email);

  // Unknown topics are refused, also from the app.
  const bad = await env.api('POST', '/feedback', { message: MSG, topic: 'tyres', t: old() }, token, ip(5));
  assert.equal(bad.status, 422);
  assert.ok(bad.json.fields.topic);

  const stored = await env.gw.repo.listFeedback();
  const a = stored.find((f) => f.topic === 'group-riding');
  assert.ok(a, 'idea stored with its topic');
  assert.equal(a.email, '');
  assert.equal(a.name, '', 'no name without "Contact me"');
  assert.equal(a.contact, false);
  assert.equal(a.source, 'app');
  assert.ok(!JSON.stringify(a).includes('idea.rider'), 'nothing identifying is stored');
  const b = stored.find((f) => f.topic === 'map-navigation');
  assert.equal(b.email, 'idea.rider@coroute.test');
  assert.equal(b.contact, true);
  assert.equal(stored.length, 2);
});
