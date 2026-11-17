const http = require('http'); const fs = require('fs'); const path = require('path');
const { chromium } = require('playwright');
const PUB = '/home/claude/app/gateway/public';
const T = { '.html': 'text/html', '.svg': 'image/svg+xml', '.woff2': 'font/woff2', '.png': 'image/png' };
// v3.63: renders public/assets/og/ride.png and friend.png (1200x630) from tool/og/invite_card_source.html.
// Run: node tool/og/render_invite_cards.js (Chromium + Playwright installed).
const SRC = path.join(__dirname, 'invite_card_source.html');
const srv = http.createServer((req, res) => { const u = new URL(req.url, 'http://x').pathname; if (u === '/__og.html') { res.writeHead(200, { 'Content-Type': 'text/html' }); return fs.createReadStream(SRC).pipe(res); } const p = path.join(PUB, u); if (!p.startsWith(PUB) || !fs.existsSync(p)) { res.writeHead(404); return res.end(); } res.writeHead(200, { 'Content-Type': T[path.extname(p)] || 'application/octet-stream' }); fs.createReadStream(p).pipe(res); }).listen(8123, async () => {
  const b = await chromium.launch(); const pg = await b.newPage({ viewport: { width: 1200, height: 630 }, deviceScaleFactor: 1 });
  for (const k of ['ride', 'friend']) { await pg.goto(`http://127.0.0.1:8123/__og.html?kind=${k}`); await pg.waitForTimeout(400); await pg.screenshot({ path: `${PUB}/assets/og/${k}.png` }); }
  await b.close(); srv.close();
});
