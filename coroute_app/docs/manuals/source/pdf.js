const { chromium } = require('playwright');
(async () => { const b = await chromium.launch(); const p = await b.newPage();
 for (const n of ['user','investor']) { await p.goto('file:///home/claude/manual/out/'+n+'.html'); await p.waitForTimeout(800);
  await p.pdf({ path: '/home/claude/manual/out/'+n+'.pdf', format: 'A4', printBackground: true, preferCSSPageSize: true }); }
 await b.close(); })();
