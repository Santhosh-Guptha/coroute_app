'use strict';
const puppeteer = require('puppeteer');

async function testModalOpen() {
  console.log('Testing Razorpay modal open directly without order_id...');
  const browser = await puppeteer.launch({
    headless: 'new',
    executablePath: 'C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe',
    args: ['--no-sandbox', '--disable-setuid-sandbox']
  });

  const page = await browser.newPage();
  page.on('console', msg => console.log('BROWSER LOG:', msg.type(), msg.text()));
  page.on('pageerror', err => console.error('BROWSER ERROR:', err.message));

  // Load a test HTML page that includes checkout.js and opens Razorpay directly
  const html = `
    <!doctype html>
    <html>
      <head>
        <title>Razorpay Test</title>
        <script src="https://checkout.razorpay.com/v1/checkout.js"></script>
      </head>
      <body>
        <button id="test-pay-btn">Pay</button>
        <div id="result">Ready</div>
        <script>
          document.getElementById('test-pay-btn').onclick = function() {
            var options = {
              key: 'rzp_test_TstfWWwQUC19Pv',
              amount: 14900,
              currency: 'INR',
              name: 'CoRoute Motorcycle Safety',
              description: 'CoRoute Pro Rider Pass',
              prefill: {
                name: 'Test Rider',
                email: 'test@coroute.app',
                contact: '+919999999999'
              },
              theme: { color: '#FF5722' },
              handler: function(response) {
                document.getElementById('result').innerText = 'SUCCESS: ' + JSON.stringify(response);
              },
              modal: {
                ondismiss: function() {
                  document.getElementById('result').innerText = 'DISMISSED';
                }
              }
            };
            var rzp = new window.Razorpay(options);
            rzp.on('payment.failed', function(resp) {
              document.getElementById('result').innerText = 'FAILED: ' + JSON.stringify(resp);
            });
            rzp.open();
          };
        </script>
      </body>
    </html>
  `;

  await page.setContent(html);
  console.log('HTML content loaded. Clicking #test-pay-btn...');
  await page.click('#test-pay-btn');

  // Wait 3 seconds for iframe to load
  await new Promise(r => setTimeout(r, 4000));

  // Check if Razorpay iframe is created in DOM
  const iframes = page.frames();
  console.log('Total frames:', iframes.length);
  for (const f of iframes) {
    console.log('Frame URL:', f.url());
  }

  // Take screenshot
  await page.screenshot({ path: 'C:/Users/santhosh/.gemini/antigravity/brain/1d66d0a6-c14d-4560-964a-508989130e9e/modal_test.png' });
  console.log('Saved screenshot to modal_test.png');

  await browser.close();
}

testModalOpen().catch(err => {
  console.error('Modal test error:', err);
  process.exit(1);
});
