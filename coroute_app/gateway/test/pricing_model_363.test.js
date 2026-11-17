'use strict';
/**
 * v3.63 pricing model: group plans (default, unchanged) or Rider Pass (one rider, every feature, 30 days, Rs 9 list
 * price). Only what is sold changes; joining stays free; a Rider Pass holder hosts rides any number of riders join.
 */
process.env.NODE_ENV = 'test';
process.env.TIMELINE_TICK_MS = '3600000';
const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const { boot } = require('./_helpers');
const pm = require('../src/pricing_model');
const { normalizePlanId, DEFAULT_SEATS } = require('../src/entitlements');
const plans = require('../src/plans');
const pricing = require('../src/plan_pricing');

let t, gw;
before(async () => { t = await boot(); gw = t.gw; });
after(async () => { await gw.shutdown(); });
let n = 0;
async function rider(name) {
  n++;
  return JSON.parse(JSON.stringify(await gw.auth.register({
    name, email: `pm${n}@coroute.test`, password: 'Password#123', phone: `+9198733${String(10000 + n).slice(-5)}`,
    vehicleType: 'Motorcycle', vehicleNo: `TS13AB${String(1000 + n).slice(-4)}`, emergencyContact: '+919000000001', emergencyContactName: 'Family Contact',
  })));
}

test('pure rules', () => {
  assert.equal(pm.onSaleIn('group_plans', 'group_small'), true);
  assert.equal(pm.onSaleIn('group_plans', 'rider_pass'), false);
  assert.equal(pm.onSaleIn('rider_pass', 'rider_pass'), true);
  assert.equal(pm.onSaleIn('rider_pass', 'group_large'), false);
  assert.equal(pm.onSaleIn('bogus', 'group_small'), true, 'unknown model = group plans');
  assert.equal(normalizePlanId('Rider Pass'), 'rider_pass');
  assert.ok(DEFAULT_SEATS.rider_pass >= 12);
  assert.equal(plans.planIdFromPlan({ category: 'rider_pass', seats: 50 }), 'rider_pass');
  assert.ok(Object.values(plans.DEFAULT_FEATURES.rider_pass).every(Boolean), 'all features on');
  const m = { status: 'ACTIVE', category: 'rider_pass', validUntil: Date.now() + 10 * 86400000, paidInr: 9, monthlyPriceInr: 9, billingPeriodDays: 30 };
  assert.equal(pricing.changeBlock({ membership: m, planId: 'rider_pass' }), null, 'a pass can be renewed early');
  const cat = { group_small: { maxCapacity: 6 }, group_large: { maxCapacity: 12 }, rider_pass: { maxCapacity: 50 } };
  assert.equal(pricing.siteMaxRiders(cat, 50), 12, 'group model: the website still says up to 12');
  assert.equal(pricing.siteMaxRiders(cat, 50, (id) => pm.onSaleIn('rider_pass', id)), 50);
});

test('catalog and orders follow the model; group plans by default', async () => {
  const u = await rider('Pass Buyer');
  const cat1 = (await t.api('GET', '/membership/catalog', null, u.token)).json.categories;
  assert.ok(cat1.group_small && cat1.group_large, 'group plans on sale by default');
  assert.equal(cat1.rider_pass, undefined, 'no Rider Pass by default');
  const refused = await t.api('POST', '/membership/order', { category: 'rider_pass' }, u.token);
  assert.equal(refused.status, 400, JSON.stringify(refused.json));

  const p = pm.forRepo(gw.repo);
  await p.set('rider_pass', 'test');
  try {
    const cat2 = (await t.api('GET', '/membership/catalog', null, u.token)).json.categories;
    assert.ok(cat2.rider_pass && cat2.community, 'Community + Rider Pass');
    assert.equal(cat2.group_small, undefined);
    assert.equal(cat2.rider_pass.priceInr, 9);
    const q = await t.api('GET', '/membership/quote?category=rider_pass', null, u.token);
    assert.equal(q.status, 200, JSON.stringify(q.json));
    const order = await t.api('POST', '/membership/order', { category: 'rider_pass' }, u.token);
    assert.ok([200, 201].includes(order.status), JSON.stringify(order.json));
    const gsmall = await t.api('POST', '/membership/order', { category: 'group_small' }, u.token);
    assert.equal(gsmall.status, 400, 'group plans not sold in the rider pass model');
  } finally { await p.set('group_plans', 'test'); }
});

test('admin: master admin only, audited, validated', async () => {
  const u = await rider('Not Admin');
  assert.equal((await t.api('GET', '/admin/pricing-model', null, u.token)).status, 403);
  assert.equal((await t.api('PUT', '/admin/pricing-model', { model: 'rider_pass' }, u.token)).status, 403);
  await assert.rejects(pm.forRepo(gw.repo).set('free_for_all', 'x'));
});
