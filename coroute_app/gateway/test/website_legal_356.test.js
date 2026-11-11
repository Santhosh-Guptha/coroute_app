'use strict';
/**
 * Public legal pages (Nov 11 2026 update): privacy / terms / delete-account agree with the app, the refund
 * policy (/refunds), the responsible disclosure page (/security) and /.well-known/security.txt, the support
 * address templating (SUPPORT_EMAIL / SECURITY_CONTACT, no personal default), and the strict CSP of the
 * marketing pages (no inline script).
 */
process.env.NODE_ENV = 'test';
process.env.SUPPORT_EMAIL = 'help@coroute.example';
process.env.SECURITY_CONTACT = 'security@coroute.example';
const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const { createApp, securityTxt } = require('../src/app');
const { MemorySoda } = require('../src/oracle/memory_soda');
const pages = require('../src/pages');

const PUB = path.join(__dirname, '..', 'public');
let gw, base;
before(async () => {
  gw = await createApp({ soda: new MemorySoda(), logger: { info() {}, warn() {}, error() {} } });
  await new Promise((r) => gw.server.listen(0, '127.0.0.1', r));
  base = `http://127.0.0.1:${gw.server.address().port}`;
});
after(async () => { await gw.shutdown(); });

const get = (p) => fetch(base + p, { redirect: 'manual' });
const text = async (p) => (await get(p)).text();
/** Visible text: no comments, scripts or tags. */
const visible = (html) => html.replace(/<!--[\s\S]*?-->/g, '').replace(/<script[\s\S]*?<\/script>/g, '').replace(/<[^>]+>/g, ' ').replace(/\s+/g, ' ');

test('no personal address: config has no built-in support e-mail; pages and partials never hard-code one', () => {
  const src = fs.readFileSync(path.join(__dirname, '..', 'src', 'config.js'), 'utf8');
  assert.match(src, /process\.env\.SUPPORT_EMAIL \|\| ''/);
  assert.match(src, /process\.env\.SECURITY_CONTACT \|\| SUPPORT_EMAIL/);
  for (const f of [...fs.readdirSync(PUB).filter((x) => x.endsWith('.html')), ...fs.readdirSync(path.join(PUB, 'partials')).map((x) => `partials/${x}`)]) {
    const html = fs.readFileSync(path.join(PUB, f), 'utf8');
    assert.ok(!/gmail\.com/i.test(html), `${f}: personal mailbox`);
  }
});

test('support e-mail blocks: the address when set, the contact form otherwise; invalid addresses are refused', () => {
  const tpl = 'A <!--support-email-->at <a href="mailto:__SUPPORT_EMAIL__">__SUPPORT_EMAIL__</a><!--/support-email--><!--no-support-email-->via form<!--/no-support-email-->'
    + ' | <!--security-email-->__SECURITY_EMAIL__<!--/security-email--><!--no-security-email-->sec form<!--/no-security-email-->';
  assert.equal(pages.applySupportEmail(tpl, 'help@x.io', 'sec@x.io'), 'A at <a href="mailto:help@x.io">help@x.io</a> | sec@x.io');
  assert.equal(pages.applySupportEmail(tpl, '', ''), 'A via form | sec form');
  assert.equal(pages.applySupportEmail(tpl, 'help@x.io'), 'A at <a href="mailto:help@x.io">help@x.io</a> | help@x.io', 'security falls back to support');
  for (const bad of ['"><script>@x.io', 'a b@x.io', 'no-at-sign', 'x@y']) assert.equal(pages.safeEmail(bad), '', bad);
});

test('privacy policy matches the app: always-on safety, diagnostics by choice, one deletion timeline, providers, grievance', async () => {
  const html = await text('/privacy');
  const v = visible(html);
  assert.ok(!html.includes('__SUPPORT_EMAIL__') && !/<!--\/?(?:no-)?support-email-->/.test(html), 'blocks resolved');
  assert.ok(!/OWNER TO FILL/.test(v), 'owner placeholders only in comments');
  assert.ok(html.includes('href="mailto:help@coroute.example"'), 'support address from SUPPORT_EMAIL');
  // Always on.
  assert.ok(!/switch crash\s+detection off|you can switch crash|off until you switch it on|Show my medical ID on the lock screen during an SOS" is off|you can turn this off/i.test(v), 'no old switches');
  assert.ok(/Crash detection runs on your phone and is always on during a ride/.test(v));
  assert.ok(/Emergency texts are always on/.test(v) && /MSG91 or Twilio/.test(v));
  assert.ok(/Medical ID on the lock screen This is always on/.test(v));
  assert.ok(/always shown on the lock screen during a ride/.test(v));
  assert.ok(/from about 12 km\/h/.test(v) && !/25 km\/h/.test(v));
  // Diagnostics by choice; the new path.
  assert.ok(/Profile, Help, Send feedback/.test(v) && !/Settings, More, Diagnostics/.test(v));
  assert.ok(/Attach diagnostics log/.test(v) && /once after a ride with an SOS or crash alarm/.test(v));
  // Deletion: path and one timeline, same as the deletion page.
  assert.ok(/Profile, Account, Delete account/.test(v) && !/Account &amp; security|Account & security/.test(html));
  assert.ok(/within 48 hours/.test(v) && /expire within 30 days/.test(v) && !/within 30 days\. You may also/.test(v));
  assert.ok(html.includes('href="/delete-account"'));
  // Providers.
  for (const p of ['Oracle Cloud', 'Hyderabad', 'Firebase Cloud Messaging', 'SMTP', 'MSG91', 'Twilio', 'Razorpay', 'Nominatim', 'Photon', 'OSRM', 'Overpass', 'Open-Meteo']) {
    assert.ok(v.includes(p), `provider ${p}`);
  }
  // E-mail and push choices, operators, plans, children, grievance.
  assert.ok(/offer e-mails/i.test(v) && /unsubscribe link/.test(v) && /each kind of news notification/.test(v));
  assert.ok(/emergency contact only if you raise an SOS during their ride/.test(v));
  assert.ok(/Group plans are bought on our website \(/.test(v) && html.includes('href="/refunds"'));
  assert.ok(/only for licensed riders aged 18 and over/.test(v));
  assert.ok(/Grievance Officer: contact us at help@coroute\.example/.test(v));
  assert.ok(/Data Protection Board of India/.test(v));
  assert.ok(!/coupon/i.test(html), 'coupons live on /plans only');
});

test('terms: roles, website payments, upgrade-only, free access modes, refunds, operators, 112', async () => {
  const v = visible(await text('/terms'));
  assert.ok(/Trip owner : the rider who created the ride/.test(v));
  assert.ok(/Trip head \(optional\): a second owner chosen by the trip owner, who can change the trip's settings only/.test(v));
  assert.ok(/Lead : a riding role, the rider at the front/.test(v));
  assert.ok(!/navigational lead|managed directly inside the mobile app|unless you turn this off/.test(v));
  assert.ok(/bought only on our website/.test(v) && /does not renew on its own/.test(v) && /you can only move to a bigger plan/.test(v));
  assert.ok(/free for everyone/.test(v) && /Refund and Cancellation Policy/.test(v));
  assert.ok(/Clubs and tour operators/.test(v) && /does not replace emergency services/.test(v) && /call 112/.test(v));
  assert.ok(/Contact us at help@coroute\.example/.test(v));
});

test('delete-account page: current app path, the same 48 hour / 30 day timeline, support address templated', async () => {
  const html = await text('/delete-account');
  const v = visible(html);
  assert.ok(/Delete account/.test(v) && /Account section/.test(v) && !/Delete My Account<\/strong>|Account &amp; Security/.test(html));
  assert.ok(/within 48 hours/.test(v) && !/24 to 48/.test(v) && /expire within 30 days/.test(v));
  assert.ok(html.includes('href="mailto:help@coroute.example?subject=Delete%20My%20CoRoute%20Account"'));
});

test('/refunds: website purchases only, no auto-renewal, full refund ends the plan, linked from shop pages and the footer', async () => {
  const r = await get('/refunds');
  assert.equal(r.status, 200);
  assert.equal(r.headers.get('content-security-policy'), pages.MARKETING_CSP);
  const html = await r.text();
  const v = visible(html);
  assert.ok(/group plans bought on our website/.test(v) && /no in-app purchases/.test(v));
  assert.ok(/does not renew on its own/.test(v) && /full refund ends the plan it paid for at once/.test(v) && /partial refund keeps the plan running/.test(v));
  assert.ok(/We reply within a few working days/.test(v) && !/OWNER TO FILL/.test(v) && html.includes('[OWNER TO FILL]'));
  assert.equal((await get('/refunds.html')).status, 200);
  for (const p of ['/plans', '/account', '/receipt', '/terms', '/privacy', '/', '/features']) {
    assert.ok((await text(p)).includes('href="/refunds"'), `${p}: links /refunds`);
  }
  const old = fs.readFileSync(path.join(PUB, 'checkout.html'), 'utf8');
  assert.ok(old.includes('href="/refunds"'), 'checkout links /refunds');
  const sm = await text('/sitemap.xml');
  assert.ok(sm.includes('/refunds</loc>') && sm.includes('/security</loc>'));
});

test('security.txt: contact from SECURITY_CONTACT, expires in a year, policy page; /security renders the address', async () => {
  for (const p of ['/.well-known/security.txt', '/security.txt']) {
    const r = await get(p);
    assert.equal(r.status, 200, p);
    assert.match(r.headers.get('content-type'), /^text\/plain/);
    const body = await r.text();
    assert.match(body, /^Contact: mailto:security@coroute\.example$/m);
    assert.match(body, new RegExp(`^Policy: ${base.replace(/[.]/g, '\\.')}/security$`, 'm'));
    const exp = Date.parse(body.match(/^Expires: (\S+)$/m)[1]);
    const days = (exp - Date.now()) / 86400000;
    assert.ok(days > 364 && days <= 365.01, `expires in ${days} days`);
  }
  // Without any address, the contact is the policy page itself.
  const t = securityTxt({ origin: 'https://x.example', contact: '', now: Date.UTC(2026, 10, 11) });
  assert.ok(t.includes('Contact: https://x.example/security\n') && t.includes('Expires: 2027-11-11T00:00:00Z\n'));
  assert.ok(securityTxt({ origin: 'https://x.example', contact: 'bad"@x' }).includes('Contact: https://x.example/security'));
  const r = await get('/security');
  assert.equal(r.status, 200);
  const html = await r.text();
  assert.ok(html.includes('href="mailto:security@coroute.example"') && html.includes('href="/.well-known/security.txt"'));
  assert.ok(/Rules for testing/.test(html) && !/OWNER TO FILL/.test(visible(html)));
});

test('marketing pages: strict CSP and no inline script (the theme line is /assets/theme-init.js)', async () => {
  const marketing = Object.keys(pages.SITE_PAGES).filter((p) => !['/plans', '/account', '/signin', '/receipt', '/checkout'].includes(p));
  for (const p of marketing) {
    const r = await get(p);
    assert.equal(r.status, 200, p);
    const csp = r.headers.get('content-security-policy');
    assert.equal(csp, pages.MARKETING_CSP, p);
    assert.ok(!/script-src[^;]*unsafe-inline/.test(csp) && csp.includes("frame-ancestors 'none'") && csp.includes("object-src 'none'"), p);
    const html = await r.text();
    // JSON-LD data blocks are not executed and are allowed; any other inline <script> is not.
    assert.ok(!/<script(?![^>]*\bsrc=)(?![^>]*type="application\/ld\+json")[^>]*>/i.test(html), `${p}: inline <script>`);
    assert.ok(!/\son[a-z]+="/i.test(html.replace(/<svg[\s\S]*?<\/svg>/g, '')), `${p}: inline event handler`);
    assert.match(html, /<script src="\/assets\/theme-init\.js\?v=[a-f0-9]+"><\/script>/, `${p}: theme-init`);
  }
});

test('operator pages: the organiser sees an emergency contact only during an SOS in their ride', () => {
  for (const f of ['clubs.html', 'ride_public.html']) {
    const html = fs.readFileSync(path.join(PUB, f), 'utf8');
    assert.ok(html.includes('Your organiser sees your emergency contact only if you raise an SOS during their ride.'), f);
  }
});
