// Contact sheets and owner previews of the generated assets, composited like the app's painter.
//   node tool/map_bikes/preview.mjs --mode sheet|map|garage|zoom --png out.png [--out <repo root>]
import { createRequire } from 'node:module';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { serve, TYPES } from './generate.mjs';

const req = createRequire(path.join(process.cwd(), 'noop.js'));
const { chromium } = req('playwright');
const args = process.argv.slice(2);
const arg = (k, d) => {
  const i = args.indexOf(k);
  return i < 0 ? d : args[i + 1];
};
const mode = arg('--mode', 'sheet');
const png = path.resolve(arg('--png', `${mode}.png`));

const COLOURS = { red: 0xd32f2f, black: 0x1b1b1b, white: 0xf4f4f4, blue: 0x1e63d6, yellow: 0xf9c80e, silver: 0xc0c0c0 };

async function main() {
  const srv = await serve();
  const port = srv.address().port;
  const browser = await chromium.launch();
  const page = await browser.newPage({ deviceScaleFactor: 1 });
  page.on('pageerror', (e) => console.error('page error:', e.message));
  page.on('console', (m) => m.type() === 'error' && console.error('page:', m.text()));
  await page.goto(`http://127.0.0.1:${port}/tool/render.html`); // same origin; we only use composite.js
  const data = await page.evaluate(
    async ([mode, TYPES, COLOURS, size]) => {
      const C = await import('/tool/composite.js');
      const cv = document.createElement('canvas');
      const ctx = cv.getContext('2d');
      const label = (t, x, y, color = '#111', px = 12) => {
        ctx.fillStyle = color;
        ctx.font = `700 ${px}px sans-serif`;
        ctx.textAlign = 'left';
        ctx.textBaseline = 'middle';
        ctx.fillText(t, x, y);
      };
      if (mode === 'sheet') {
        const cols = Object.entries(COLOURS);
        const rots = [0, 45, 135];
        const cell = 64;
        const rows = TYPES.length * 2;
        const W = 110 + cols.length * rots.length * cell * 2 + 30, H = rows * cell + 40;
        cv.width = W;
        cv.height = H;
        const half = 110 + cols.length * rots.length * cell;
        C.mapBackground(ctx, W, H, false, 5);
        ctx.save();
        ctx.beginPath();
        ctx.rect(half + 10, 0, W, H);
        ctx.clip();
        C.mapBackground(ctx, W, H, true, 5);
        ctx.restore();
        for (let ti = 0; ti < TYPES.length; ti++) {
          for (const r of [1, 2]) {
            const row = ti * 2 + (r - 1);
            const y = 30 + row * cell + cell / 2;
            label(`${TYPES[ti]} ${r === 2 ? '+P' : ''}`, 6, y);
            let i = 0;
            for (const [, argb] of cols) {
              for (const h of rots) {
                for (const side of [0, 1]) {
                  const x = (side ? half + 10 : 110) + i * cell + cell / 2;
                  await C.drawMarker(ctx, x, y, { type: TYPES[ti], riders: r, argb, heading: h, size: size ?? 44, cue: 'normal', ring: 0x9aa3ad });
                }
                i++;
              }
            }
          }
        }
        label('light map', 110, 14);
        label('dark map', half + 10, 14, '#eee');
      } else if (mode === 'types') {
        // Every type side by side at the cockpit size: rows = types, columns = 1 rider / pillion ×
        // red / black / white, light map left, dark map right (heading 0 and a turned copy).
        const cols = [COLOURS.red, COLOURS.black, COLOURS.white];
        const cell = Math.max(64, Math.round((size ?? 57) * 1.25));
        const per = cols.length * 2 * 2; // colours × riders × headings
        const lab = 92;
        const half = lab + per * cell;
        cv.width = half * 2 - lab + 20;
        cv.height = TYPES.length * cell + 34;
        C.mapBackground(ctx, cv.width, cv.height, false, 5);
        ctx.save();
        ctx.beginPath();
        ctx.rect(half + 10, 0, cv.width, cv.height);
        ctx.clip();
        C.mapBackground(ctx, cv.width, cv.height, true, 5);
        ctx.restore();
        for (let ti = 0; ti < TYPES.length; ti++) {
          const y = 30 + ti * cell + cell / 2;
          label(TYPES[ti], 6, y, '#111', 13);
          let i = 0;
          for (const r of [1, 2]) {
            for (const argb of cols) {
              for (const h of [0, 60]) {
                for (const side of [0, 1]) {
                  const x = (side ? half + 10 : lab) + i * cell + cell / 2;
                  await C.drawMarker(ctx, x, y, { type: TYPES[ti], riders: r, argb, heading: h, size: size ?? 57, cue: 'normal', ring: 0x9aa3ad });
                }
                i++;
              }
            }
          }
        }
        label(`light map · ${size ?? 57} px · 1 rider | with pillion`, lab, 14);
        label('dark map', half + 10, 14, '#eee');
      } else if (mode === 'zoom') {
        const cols = Object.values(COLOURS);
        const cell = 200;
        cv.width = cols.length * cell;
        cv.height = TYPES.length * cell;
        C.mapBackground(ctx, cv.width, cv.height, false, 9);
        for (let ti = 0; ti < TYPES.length; ti++) {
          for (let ci = 0; ci < cols.length; ci++) {
            await C.drawMarker(ctx, ci * cell + cell / 2, ti * cell + cell / 2, { type: TYPES[ti], riders: ci % 2 ? 2 : 1, argb: cols[ci], heading: 0, size: 192, cue: 'normal', ring: 0x9aa3ad });
          }
          label(TYPES[ti], 6, ti * cell + 12);
        }
      } else if (mode === 'map') {
        // a 2.0x phone screen: logical 760 × 520, the 2.0x images (as Flutter picks them)
        cv.width = 1520;
        cv.height = 1040;
        ctx.scale(2, 2);
        C.mapBackground(ctx, 760, 520, false, 11);
        // a route
        ctx.strokeStyle = 'rgba(47,124,246,0.85)';
        ctx.lineWidth = 7;
        ctx.lineCap = 'round';
        ctx.beginPath();
        ctx.moveTo(60, 470);
        ctx.bezierCurveTo(200, 380, 260, 330, 380, 300);
        ctx.bezierCurveTo(520, 270, 600, 170, 720, 60);
        ctx.stroke();
        const M = [
          { type: 'adventure', riders: 1, argb: COLOURS.white, x: 655, y: 120, heading: 42, role: 'L', label: 'LEAD · Arjun', labelColor: '#0e7c86', status: 0x22c55e, ring: 0x0e7c86 },
          { type: 'sport', riders: 1, argb: COLOURS.red, x: 560, y: 205, heading: 50, label: 'Meera', status: 0x22c55e, ring: 0xe11d48, labelColor: '#e11d48' },
          { type: 'cruiser', riders: 2, argb: COLOURS.black, x: 455, y: 270, heading: 62, label: 'Asha + Kiran', status: 0x22c55e, ring: 0x7c3aed, labelColor: '#7c3aed', selected: true },
          { type: 'retro', riders: 1, argb: 0x6d4c41, x: 345, y: 312, heading: 78, label: 'You', labelColor: '#111827', me: true, status: 0x22c55e },
          { type: 'scooter', riders: 1, argb: COLOURS.yellow, x: 240, y: 362, heading: 58, label: 'Ravi', status: 0xf59e0b, ring: 0xf59e0b, cue: 'stopped', labelColor: '#b45309' },
          { type: 'electric', riders: 1, argb: COLOURS.blue, x: 130, y: 300, heading: 145, label: 'Neha · SOS', status: 0xe53935, cue: 'sos', labelColor: '#e53935' },
          { type: 'offroad', riders: 1, argb: 0x2e7d32, x: 120, y: 440, heading: 30, role: 'S', label: 'Dev', status: 0x22c55e, ring: 0x0891b2, labelColor: '#0891b2' },
          { type: 'commuter', riders: 1, argb: COLOURS.silver, x: 640, y: 380, heading: 200, label: 'Sam · offline', status: 0x9ca3af, cue: 'stale', labelColor: '#6b7280' },
        ];
        for (const m of M) await C.drawMarker(ctx, m.x, m.y, { ...m, size: m.me ? 65 : 57, scale: 2 });
        label('Preview: 3D rider markers (light map)', 14, 18, '#111', 14);
      } else if (mode === 'garage') {
        const cw = 220, ch = 170;
        cv.width = (cw * 4 + 20) * 2;
        cv.height = (ch * 4 + 20) * 2;
        ctx.scale(2, 2);
        ctx.fillStyle = '#f3f4f6';
        ctx.fillRect(0, 0, cw * 4 + 20, ch * 4 + 20);
        const cols = [0xd32f2f, 0x1b1b1b, 0xf4f4f4, 0x1e63d6, 0xf9c80e, 0x6d4c41, 0x2e7d32, 0xc0c0c0];
        for (let i = 0; i < TYPES.length * 2; i++) {
          const t = TYPES[i % 8];
          const two = i >= 8;
          const x = 10 + (i % 4) * cw, y = 10 + Math.floor(i / 4) * ch;
          ctx.fillStyle = '#ffffff';
          ctx.beginPath();
          ctx.roundRect(x + 6, y + 6, cw - 12, ch - 12, 14);
          ctx.fill();
          ctx.strokeStyle = '#e5e7eb';
          ctx.stroke();
          await C.drawHero(ctx, x + 14, y + 12, 192, 120, { type: t, riders: two ? 2 : 0, argb: cols[(i + (two ? 3 : 0)) % 8] });
          label(`${t}${two ? ' (2-up)' : ''}`, x + 18, y + ch - 24, '#111', 13);
        }
      }
      return cv.toDataURL('image/png');
    },
    [mode, TYPES, COLOURS, Number(arg('--size', 44))],
  );
  fs.writeFileSync(png, Buffer.from(data.split(',')[1], 'base64'));
  console.log('wrote', png);
  await browser.close();
  srv.close();
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) main();
