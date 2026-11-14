'use strict';
/**
 * v3.58 brand for every e-mail CoRoute sends: the helmet wordmark as a hosted PNG (mail apps do not show SVG),
 * with a teal text "CoRoute" as the alt text so a client that blocks images still shows the name.
 * Colours match the app and the website (docs/brand/BRAND_GUIDE_v3.58.md).
 */
const EMAIL_BRAND = Object.freeze({
  teal: '#2B7A8C',      // buttons, links, header text
  tealTint: '#E3F0F2',  // soft backgrounds (coupon box, step numbers)
  tealOnDark: '#8FCBD7', // links and accents in dark-mode mail apps
  amber: '#D9822B',
});

const WORDMARK_PATH = '/brand/email-wordmark.png'; // 300 x 56, shown at 150 x 28

function escAttr(s) {
  return String(s).replace(/&/g, '&amp;').replace(/"/g, '&quot;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}

/** Inner HTML of the header cell: the wordmark image when the site address is known, else the teal name. */
function brandHeaderInner(origin) {
  const o = String(origin || '').replace(/\/+$/, '');
  const text = `<span style="font-size:16px;font-weight:800;color:${EMAIL_BRAND.teal};letter-spacing:-.2px;">CoRoute</span>`;
  if (!/^https?:\/\//.test(o)) return text;
  return `<img src="${escAttr(o + WORDMARK_PATH)}" width="150" height="28" alt="CoRoute" `
    + `style="display:block;width:150px;height:28px;border:0;outline:none;text-decoration:none;font-size:16px;font-weight:800;color:${EMAIL_BRAND.teal};">`;
}

/** A full table row for the table-based layouts. */
function brandHeaderRow(origin, cls = '') {
  return `<tr><td${cls ? ` class="${cls}"` : ''} style="padding-bottom:18px;">${brandHeaderInner(origin)}</td></tr>`;
}

module.exports = { EMAIL_BRAND, WORDMARK_PATH, brandHeaderInner, brandHeaderRow };
