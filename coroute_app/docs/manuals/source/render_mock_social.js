const { chromium } = require('playwright');
// Round 4 (Nov 9) mock-ups: run from /home/claude/manual after `cd mock && python3 gen_social.py`.
(async () => {
  const b = await chromium.launch(); const p = await b.newPage({ viewport:{width:420,height:900}, deviceScaleFactor:2 });
  await p.route(/fonts\.(googleapis|gstatic)\.com/, r => r.abort());
  for (const f of ['s01_profile','s02_friends','s03_crew_poll','s04_score','s05_leaderboard','s06_bikemap','s07_pillion','s08_pillion_rider','s09_completebike','s10_ride_invite','s11_crew_ride_pick']) { await p.goto('file://'+process.cwd()+'/mock/html/'+f+'.html'); await p.waitForTimeout(150); await (await p.$('#ph')).screenshot({path:'shots/m_'+f+'.png'}); }
  await b.close();
})();
