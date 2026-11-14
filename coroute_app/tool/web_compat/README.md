# tool/web_compat: CSS fallbacks for older phone browsers

`css_compat.js` adds fallbacks next to modern CSS in `gateway/public`. Run it after **any** website CSS change
(the gateway test `website_device_compat_358.test.js` fails when you forget):

```
cd tool/web_compat
npm install          # postcss only; not part of the gateway runtime
node css_compat.js   # rewrites gateway/public/**/*.css and inline <style> blocks in place
node css_compat.js --check   # exit 1 if something would change
```

The tool is safe to run again: it first removes what it added (`/* compat */` lines and `compat:generated` blocks).
Never edit those lines by hand. What it does and why: docs/quality/WEBSITE_DEVICE_COMPAT_v3.58.md.
