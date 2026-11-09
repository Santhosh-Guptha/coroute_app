const { chromium } = require('playwright');
(async () => {
  const b = await chromium.launch();
  const p = await b.newPage({ viewport: { width: 600, height: 1000 }, deviceScaleFactor: 2 });
  await p.route(/fonts\.(googleapis|gstatic)\.com/, r => r.abort());
  const f = process.argv[2], out = process.argv[3];
  await p.goto('file://' + f); await p.waitForTimeout(400);
  const box = await p.evaluate(() => { const el=[...document.body.querySelectorAll('div')].find(d=>{const r=d.getBoundingClientRect();return r.width>300&&r.width<500&&r.height>600}); const r=el.getBoundingClientRect(); return {x:r.x,y:r.y,width:r.width,height:r.height}; });
  await p.screenshot({ path: out, clip: box });
  await b.close();
})();
