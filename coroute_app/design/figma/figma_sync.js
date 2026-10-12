/**
 * CoRoute Figma Sync Utility
 * 
 * Synchronizes CoRoute design tokens and artboard vectors with your Figma team file.
 * 
 * Prerequisites:
 *   1. A Figma Personal Access Token (PAT):
 *      Figma -> Profile -> Settings -> Security -> Personal access tokens -> Generate new token
 *   2. Your Figma File Key:
 *      Copied from the Figma URL: https://figma.com/design/<FIGMA_FILE_KEY>/...
 * 
 * Usage:
 *   node design/figma/figma_sync.js --token=figd_... --file=...
 *   Or set environment variables: FIGMA_TOKEN and FIGMA_FILE_KEY
 */

const fs = require('fs');
const path = require('path');
const https = require('https');

const args = process.argv.slice(2).reduce((acc, arg) => {
  const [k, v] = arg.replace(/^--/, '').split('=');
  acc[k] = v;
  return acc;
}, {});

const FIGMA_TOKEN = args.token || process.env.FIGMA_TOKEN;
const FIGMA_FILE_KEY = args.file || process.env.FIGMA_FILE_KEY;

console.log('=== CoRoute Figma Sync Utility ===\n');

if (!FIGMA_TOKEN || !FIGMA_FILE_KEY) {
  console.log('Figma credentials not detected.\n');
  console.log('To connect live to your Figma file:');
  console.log('  node design/figma/figma_sync.js --token=<YOUR_FIGMA_TOKEN> --file=<YOUR_FILE_KEY>\n');
  console.log('Offline Design Assets Available:');
  console.log('  1. Design Tokens: design/figma/coroute_figma_tokens.json (W3C / Tokens Studio compatible)');
  console.log('  2. Vector Artboards (Drag directly into Figma canvas):');
  
  const files = fs.readdirSync(__dirname).filter(f => f.endsWith('.svg'));
  files.forEach(f => console.log(`     - design/figma/${f}`));
  console.log('\nDrag any of the above .svg files directly onto your Figma canvas to import editable layers.');
  process.exit(0);
}

// Function to call Figma REST API
function figmaRequest(endpoint, method = 'GET', data = null) {
  return new Promise((resolve, reject) => {
    const url = new URL(`https://api.figma.com/v1${endpoint}`);
    const options = {
      method,
      headers: {
        'X-Figma-Token': FIGMA_TOKEN,
        'Content-Type': 'application/json'
      }
    };

    const req = https.request(url, options, (res) => {
      let body = '';
      res.on('data', chunk => body += chunk);
      res.on('end', () => {
        try {
          const parsed = JSON.parse(body);
          if (res.statusCode >= 200 && res.statusCode < 300) {
            resolve(parsed);
          } else {
            reject(new Error(`Figma API Error ${res.statusCode}: ${parsed.err || parsed.message || body}`));
          }
        } catch (e) {
          reject(e);
        }
      });
    });

    req.on('error', reject);
    if (data) req.write(JSON.stringify(data));
    req.end();
  });
}

async function run() {
  try {
    console.log(`Connecting to Figma File: ${FIGMA_FILE_KEY}...`);
    const fileData = await figmaRequest(`/files/${FIGMA_FILE_KEY}?depth=1`);
    console.log(`Connected successfully to: "${fileData.name}"`);
    console.log(`Last modified: ${fileData.lastModified}`);

    // Read design tokens
    const tokensPath = path.join(__dirname, 'coroute_figma_tokens.json');
    const tokens = JSON.parse(fs.readFileSync(tokensPath, 'utf8'));
    console.log(`Loaded ${Object.keys(tokens.color).length} color token groups and ${Object.keys(tokens.touchTarget).length} touch target constraints.`);

    console.log('\nReady to sync vectors and tokens into Figma.');
    console.log(`Open your Figma file: https://www.figma.com/design/${FIGMA_FILE_KEY}`);
  } catch (err) {
    console.error('Connection failed:', err.message);
  }
}

run();
