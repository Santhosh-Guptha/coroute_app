'use strict';
process.env.NODE_ENV = 'test';
/**
 * "Up to N riders" on the website (__MAX_RIDERS__): the largest paid plan on sale in the membership
 * catalog (maxCapacity, else capacity), 12 when the catalog says nothing. MAX_CONVOY_RIDERS is only
 * a safety ceiling that caps it; it is never the advertised number.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const { siteMaxRiders } = require('../src/plan_pricing');

const plan = (seats, extra = {}) => ({ capacity: seats, maxCapacity: seats, isActive: true, ...extra });

test('largest paid plan on sale, from maxCapacity', () => {
  assert.equal(siteMaxRiders({ community: plan(1), group_small: plan(6), group_large: plan(12) }, 50), 12);
  assert.equal(siteMaxRiders({ group_small: plan(6), group_large: { capacity: 10, maxCapacity: 15, isActive: true } }, 50), 15);
  assert.equal(siteMaxRiders({ group_small: plan(6), group_large: { capacity: 14, isActive: true } }, 50), 14, 'capacity when maxCapacity is missing');
});

test('a plan off sale is not advertised; Community never counts', () => {
  assert.equal(siteMaxRiders({ community: plan(40), group_small: plan(6), group_large: plan(12, { isActive: false }) }, 50), 6);
});

test('fallback 12 when the catalog has nothing usable', () => {
  assert.equal(siteMaxRiders(null, 50), 12);
  assert.equal(siteMaxRiders({}, 50), 12);
  assert.equal(siteMaxRiders({ group_small: { isActive: false }, group_large: { isActive: false } }, 50), 12);
  assert.equal(siteMaxRiders({ group_large: { capacity: 'x' } }), 12);
});

test('MAX_CONVOY_RIDERS only caps the number, it is never the number', () => {
  assert.equal(siteMaxRiders({ group_large: plan(12) }, 8), 8);
  assert.notEqual(siteMaxRiders({ group_large: plan(12) }, 50), 50);
  assert.equal(siteMaxRiders({ group_large: plan(100) }, 50), 50);
});
