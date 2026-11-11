// Renders the handbook HTML files listed in a jobs.json to A4 PDFs (Playwright + Chromium, pre-installed).
const { chromium } = require('playwright');
const fs = require('fs');
(async () => {
  const jobs = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
  const browser = await chromium.launch();
  const page = await browser.newPage();
  for (const j of jobs) {
    await page.goto('file://' + j.html, { waitUntil: 'load' });
    await page.evaluate(() => document.fonts.ready);
    await page.waitForTimeout(300);
    const foot = `<div style="width:100%;font-family:sans-serif;font-size:7.5px;color:#5A6B75;padding:0 17mm;display:flex;justify-content:space-between;">
      <span>CoRoute · ${j.title.replace(/&/g, '&amp;').replace(/</g, '&lt;')}</span><span>Page <span class="pageNumber"></span> of <span class="totalPages"></span></span></div>`;
    await page.pdf({ path: j.pdf, format: 'A4', printBackground: true, preferCSSPageSize: true,
      displayHeaderFooter: true, headerTemplate: '<div></div>', footerTemplate: foot });
    console.log('rendered', j.name);
  }
  await browser.close();
})();
