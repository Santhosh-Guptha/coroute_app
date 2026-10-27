'use strict';
const puppeteer = require('puppeteer');

async function debugRazorpayIframe() {
  const browser = await puppeteer.launch({
    headless: 'new',
    executablePath: 'C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe',
    args: ['--no-sandbox', '--disable-setuid-sandbox']
  });

  const page = await browser.newPage();
  page.on('response', async res => {
    if (res.status() >= 400) {
      let body = '';
      try { body = (await res.text()).slice(0, 300); } catch {}
      console.log(`HTTP ${res.status()} from ${res.url()}`);
      if (body) console.log('Response body:', body);
    }
  });

  const html = `
    <!doctype html>
    <html>
      <head>
        <title>Razorpay Test</title>
        <script src="https://checkout.razorpay.com/v1/checkout.js"></script>
      </head>
      <body>
        <script>
          window.onload = function() {
            var options = {
              key: 'rzp_test_TstfWWwQUC19Pv',
              amount: 14900,
              currency: 'INR',
              name: 'CoRoute Test',
              handler: function(resp) {
                console.log('PAYMENT SUCCESS:', resp);
              }
            };
            var rzp = new window.Razorpay(options);
            rzp.on('payment.failed', function(resp) {
              console.log('PAYMENT FAILED EVENT:', resp);
            });
            rzp.open();
          };
        </script>
      </body>
    </html>
  `;

  await page.setContent(html);
  await new Promise(r => setTimeout(r, 6000));
  await page.screenshot({ path: 'C:/Users/santhosh/Documents/antigravity/wise-chandrasekhar/coroute_app/gateway/test/debug_checkout.png' });
  console.log('Saved debug_checkout.png');
  await browser.close();
}

debugRazorpayIframe().catch(console.error);
