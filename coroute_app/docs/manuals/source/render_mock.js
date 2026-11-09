const { chromium } = require('playwright'); const fs=require('fs');
(async () => {
  const b = await chromium.launch(); const p = await b.newPage({ viewport:{width:420,height:900}, deviceScaleFactor:2 });
  await p.route(/fonts\.(googleapis|gstatic)\.com/, r => r.abort());
  for (const f of fs.readdirSync('mock/html')) { await p.goto('file://'+process.cwd()+'/mock/html/'+f); await p.waitForTimeout(150); await (await p.$('#ph')).screenshot({path:'shots/m_'+f.replace('.html','.png')}); }
  const q = await b.newPage({ viewport:{width:1280,height:800}, deviceScaleFactor:2 }); await q.route(/fonts\.(googleapis|gstatic)\.com/, r => r.abort());
  await q.goto('file://'+process.cwd()+'/assets/coroute_app/design/extracted_screens/light/16_Admin_operations_dashboard.html'); await q.waitForTimeout(400);
  await q.screenshot({path:'shots/d_16_admin.png', fullPage:false});
  await b.close();
})();
