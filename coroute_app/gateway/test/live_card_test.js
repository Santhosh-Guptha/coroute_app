'use strict';
const puppeteer = require('puppeteer');

async function testCardPayment() {
  console.log('=== TESTING CARD PAYMENT WITH TEST CARD 4100 2800 0000 1007 ===');
  const browser = await puppeteer.launch({
    headless: 'new',
    executablePath: 'C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe',
    args: ['--no-sandbox', '--disable-setuid-sandbox']
  });

  const page = await browser.newPage();
  await page.setViewport({ width: 1280, height: 900 });

  await page.goto('https://coroute.duckdns.org/checkout', { waitUntil: 'networkidle2' });

  // Select Road Captain
  const capCard = await page.$('[data-tier="roadCaptain"]');
  if (capCard) await capCard.click();

  await page.evaluate(() => {
    document.getElementById('rider-name').value = 'Test Card Rider';
    document.getElementById('rider-email').value = 'card.rider@coroute.app';
    document.getElementById('rider-phone').value = '+919876543211';
  });

  // Click Pay
  const payBtn = await page.$('#pay-btn');
  await payBtn.click();

  // Wait for modal
  await page.waitForSelector('#rzp-test-modal', { visible: true, timeout: 10000 });

  // Switch to Card tab
  const tabCardBtn = await page.$('#tab-card-btn');
  await tabCardBtn.click();

  // Click Submit Card
  const submitCardBtn = await page.$('#btn-submit-card');
  await submitCardBtn.click();

  // Wait for verified result
  await page.waitForFunction(() => {
    const box = document.getElementById('status-box');
    return box && box.classList.contains('success');
  }, { timeout: 15000 });

  const statusText = await page.$eval('#status-box', el => el.innerText);
  console.log('\n=== CARD PAYMENT RESULT ===');
  console.log(statusText);
  console.log('===========================\n');

  const cardScreenshot = 'C:/Users/santhosh/.gemini/antigravity/brain/1d66d0a6-c14d-4560-964a-508989130e9e/live_test_card_success.png';
  await page.screenshot({ path: cardScreenshot });
  console.log('Saved card screenshot to:', cardScreenshot);

  await browser.close();
}

testCardPayment().catch(err => {
  console.error('Card test failed:', err);
  process.exit(1);
});
