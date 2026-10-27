'use strict';
const puppeteer = require('puppeteer');

async function executeTestTransaction() {
  console.log('=== STARTING LIVE END-TO-END TEST TRANSACTION ===');
  console.log('Target: https://coroute.duckdns.org/checkout');

  const browser = await puppeteer.launch({
    headless: 'new',
    executablePath: 'C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe',
    args: ['--no-sandbox', '--disable-setuid-sandbox']
  });

  const page = await browser.newPage();
  await page.setViewport({ width: 1280, height: 900 });

  page.on('console', msg => console.log('[BROWSER CONSOLE]', msg.type(), msg.text()));
  page.on('pageerror', err => console.error('[BROWSER ERROR]', err.message));

  console.log('1. Navigating to https://coroute.duckdns.org/checkout ...');
  await page.goto('https://coroute.duckdns.org/checkout', { waitUntil: 'networkidle2' });

  console.log('2. Page loaded. Selecting plan CoRoute Pro (Rs 149/mo) ...');
  const proCard = await page.$('[data-tier="proRider"]');
  if (proCard) await proCard.click();

  // Fill in rider details
  await page.evaluate(() => {
    document.getElementById('rider-name').value = 'Test UPI Rider';
    document.getElementById('rider-email').value = 'test.rider@coroute.app';
    document.getElementById('rider-phone').value = '+919876543210';
  });

  console.log('3. Clicking Pay Button ...');
  const payBtn = await page.$('#pay-btn');
  await payBtn.click();

  // Wait for the modal to display
  console.log('4. Waiting for Razorpay Payment Modal ...');
  await page.waitForSelector('#rzp-test-modal', { visible: true, timeout: 10000 });
  console.log('   Razorpay Modal is visible!');

  // Verify test@razorpay is in UPI input
  const upiVal = await page.$eval('#test-upi-input', el => el.value);
  console.log('5. UPI Input value:', upiVal);

  console.log('6. Submitting test UPI payment to test@razorpay ...');
  const submitUpiBtn = await page.$('#btn-submit-upi');
  await submitUpiBtn.click();

  // Wait for status box to show success
  console.log('7. Waiting for backend cryptographic signature verification (POST /api/verify-payment) ...');
  await page.waitForFunction(() => {
    const box = document.getElementById('status-box');
    return box && box.classList.contains('success');
  }, { timeout: 15000 });

  const statusText = await page.$eval('#status-box', el => el.innerText);
  console.log('\n=== PAYMENT VERIFICATION RESULT ===');
  console.log(statusText);
  console.log('====================================\n');

  // Save screenshot of the verified payment
  const screenshotPath = 'C:/Users/santhosh/.gemini/antigravity/brain/1d66d0a6-c14d-4560-964a-508989130e9e/live_test_payment_success.png';
  await page.screenshot({ path: screenshotPath });
  console.log('Saved screenshot of successful payment to:', screenshotPath);

  await browser.close();
  console.log('Test completed successfully!');
}

executeTestTransaction().catch(err => {
  console.error('Test transaction failed:', err);
  process.exit(1);
});
