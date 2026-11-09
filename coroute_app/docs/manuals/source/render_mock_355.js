const { chromium } = require('playwright');
(async () => {
  const b = await chromium.launch(); const p = await b.newPage({ viewport:{width:420,height:900}, deviceScaleFactor:2 });
  await p.route(/fonts\.(googleapis|gstatic)\.com/, r => r.abort());
  for (const f of ['i11_missing','i14_lockscreen','i15_siren','i16_horn','i17_voicesound','i18_movingchip']) { await p.goto('file://'+process.cwd()+'/mock/html/'+f+'.html'); await p.waitForTimeout(150); await (await p.$('#ph')).screenshot({path:'shots/m_'+f+'.png'}); }
  await b.close();
})();
