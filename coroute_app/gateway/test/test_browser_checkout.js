'use strict';
const puppeteer = require('puppeteer');

async function testBrowser() {
  console.log('Launching browser to test https://coroute.duckdns.org/checkout ...');
  const browser = await puppeteer.launch({
    headless: 'new',
    executablePath: 'C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe',
    args: ['--no-sandbox', '--disable-setuid-sandbox']
  });

  const page = await browser.newPage();
  page.on('console', msg => console.log('BROWSER LOG:', msg.type(), msg.text()));
  page.on('pageerror', err => console.error('BROWSER ERROR:', err.message));

  await page.goto('https://coroute.duckdns.org/checkout', { waitUntil: 'networkidle2' });
  console.log('Page title:', await page.title());

  // Click on pay button
  const payBtn = await page.$('#pay-btn');
  console.log('Found pay button:', Boolean(payBtn));
  await payBtn.click();

  // Wait 4 seconds for response
  await new Promise(r => setTimeout(r, 4000));

  const statusText = await page.$eval('#status-box', el => el.innerText);
  console.log('Status Box Text:\n', statusText);

  // Take screenshot
  await page.screenshot({ path: 'C:/Users/santhosh/.gemini/antigravity/brain/1d66d0a6-c14d-4560-964a-508989130e9e/checkout_test.png' });
  console.log('Saved screenshot to checkout_test.png');

  await browser.close();
}

testBrowser().catch(err => {
  console.error('Test browser error:', err);
  process.exit(1);
});
