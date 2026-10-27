'use strict';
const fs = require('fs');
const html = fs.readFileSync('coroute_app/gateway/public/checkout.html', 'utf8');
const scripts = html.match(/<script>([\s\S]*?)<\/script>/g);
for (const s of scripts) {
  const code = s.replace(/<script>|<\/script>/g, '');
  new Function(code);
}
console.log('ALL scripts in checkout.html parsed with ZERO syntax errors!');
