/* CoRoute Play listing art: shared helpers (map generator, 3D bike markers, icons, chrome). */
(function () {
  const P = {
    light: { land: '#ECE8E1', block: '#E4DFD6', park: '#DCE5D1', water: '#CADDE6', casing: '#DCD5CA', road: '#FFFFFF',
      majCase: '#E3C79B', major: '#F5DFB8', label: '#7A7F86', route: '#2B7A8C', routeCase: '#FFFFFF' },
    dark: { land: '#23272C', block: '#272C32', park: '#24302A', water: '#1D2C35', casing: '#1A1D21', road: '#30363E',
      majCase: '#2A2621', major: '#4A4134', label: '#A5A29B', route: '#5FB3C4', routeCase: '#15181C' },
  };
  const MEMBERS = {
    light: ['#2B7A8C', '#3E8E5E', '#B9821C', '#B5546E', '#3D7BC8', '#7A62B0', '#2E8F86', '#D9822B'],
    dark: ['#5FB3C4', '#6CC08B', '#E0B15A', '#E58BA3', '#79A8E8', '#A993DE', '#63C2B6', '#E9A55B'],
  };
  function rng(seed) { let a = seed >>> 0; return () => { a |= 0; a = (a + 0x6D2B79F5) | 0; let t = Math.imul(a ^ (a >>> 15), 1 | a); t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t; return ((t ^ (t >>> 14)) >>> 0) / 4294967296; }; }
  function smooth(pts, closed) {
    if (pts.length < 2) return '';
    const p = closed ? [pts[pts.length - 1], ...pts, pts[0], pts[1]] : [pts[0], ...pts, pts[pts.length - 1]];
    let d = `M${p[1][0].toFixed(1)} ${p[1][1].toFixed(1)}`;
    for (let i = 1; i < p.length - 2; i++) {
      const [p0, p1, p2, p3] = [p[i - 1], p[i], p[i + 1], p[i + 2]];
      const c1 = [p1[0] + (p2[0] - p0[0]) / 6, p1[1] + (p2[1] - p0[1]) / 6];
      const c2 = [p2[0] - (p3[0] - p1[0]) / 6, p2[1] - (p3[1] - p1[1]) / 6];
      d += ` C${c1[0].toFixed(1)} ${c1[1].toFixed(1)} ${c2[0].toFixed(1)} ${c2[1].toFixed(1)} ${p2[0].toFixed(1)} ${p2[1].toFixed(1)}`;
    }
    return closed ? d + 'Z' : d;
  }
  function blob(r, cx, cy, rad, n = 8) {
    const pts = []; for (let i = 0; i < n; i++) { const a = (i / n) * Math.PI * 2; const rr = rad * (0.7 + r() * 0.5); pts.push([cx + Math.cos(a) * rr, cy + Math.sin(a) * rr * 0.8]); }
    return smooth(pts, true);
  }

  /* makeMap(el, {w,h,seed,dark,route:[[x,y]..], routes:[{pts,color,width}], major:[[[x,y]..]], towns:[[x,y,r]], labels:[[x,y,text,size]], river:[[x,y]..], parks:[[x,y,r]]}) */
  function makeMap(el, o) {
    const c = o.dark ? P.dark : P.light; const r = rng(o.seed || 7); const w = o.w, h = o.h;
    let s = `<svg class="tiles" width="${w}" height="${h}" viewBox="0 0 ${w} ${h}" xmlns="http://www.w3.org/2000/svg">`;
    s += `<rect width="${w}" height="${h}" fill="${c.land}"/>`;
    // building blocks in towns
    (o.towns || []).forEach(([tx, ty, tr]) => {
      for (let i = 0; i < tr * 1.1; i++) {
        const a = r() * Math.PI * 2, d = Math.sqrt(r()) * tr; const x = tx + Math.cos(a) * d, y = ty + Math.sin(a) * d;
        const bw = 10 + r() * 22, bh = 8 + r() * 18; s += `<rect x="${x.toFixed(1)}" y="${y.toFixed(1)}" width="${bw.toFixed(1)}" height="${bh.toFixed(1)}" rx="2" fill="${c.block}" transform="rotate(${(o.gridAngle || 12)} ${x.toFixed(1)} ${y.toFixed(1)})"/>`;
      }
    });
    (o.parks || []).forEach(([px, py, pr]) => { s += `<path d="${blob(r, px, py, pr)}" fill="${c.park}"/>`; });
    if (o.lake) s += `<path d="${blob(r, o.lake[0], o.lake[1], o.lake[2], 9)}" fill="${c.water}"/>`;
    if (o.river) s += `<path d="${smooth(o.river)}" fill="none" stroke="${c.water}" stroke-width="${o.riverW || 18}" stroke-linecap="round"/>`;
    // minor roads: a jittered grid around the towns plus some long country roads
    const minor = [];
    const ga = ((o.gridAngle || 12) * Math.PI) / 180;
    (o.towns || []).forEach(([tx, ty, tr]) => {
      const step = o.gridStep || 46;
      for (let k = -Math.ceil(tr / step) - 1; k <= Math.ceil(tr / step) + 1; k++) {
        for (const rot of [0, Math.PI / 2]) {
          const a = ga + rot; const nx = -Math.sin(a), ny = Math.cos(a); const off = k * step + (r() - 0.5) * 12;
          const cx = tx + nx * off, cy = ty + ny * off; const L = tr * (1.1 + r() * 0.5); const pts = [];
          for (let j = -2; j <= 2; j++) { const t = (j / 2) * L; pts.push([cx + Math.cos(a) * t + (r() - 0.5) * 8, cy + Math.sin(a) * t + (r() - 0.5) * 8]); }
          minor.push(pts);
        }
      }
    });
    for (let i = 0; i < (o.country || 7); i++) {
      const x0 = r() * w, y0 = r() * h, a = r() * Math.PI, L = Math.max(w, h) * 0.9; const pts = [];
      for (let j = -3; j <= 3; j++) { const t = (j / 3) * L; pts.push([x0 + Math.cos(a) * t + (r() - 0.5) * 60, y0 + Math.sin(a) * t + (r() - 0.5) * 60]); }
      minor.push(pts);
    }
    const md = minor.map(p => smooth(p)).join(' ');
    s += `<path d="${md}" fill="none" stroke="${c.casing}" stroke-width="7" stroke-linecap="round" stroke-linejoin="round"/>`;
    s += `<path d="${md}" fill="none" stroke="${c.road}" stroke-width="4.6" stroke-linecap="round" stroke-linejoin="round"/>`;
    const majors = (o.major || []).concat(o.route ? [o.route] : []);
    const jd = majors.map(p => smooth(p)).join(' ');
    s += `<path d="${jd}" fill="none" stroke="${c.majCase}" stroke-width="12" stroke-linecap="round" stroke-linejoin="round"/>`;
    s += `<path d="${jd}" fill="none" stroke="${c.major}" stroke-width="9.5" stroke-linecap="round" stroke-linejoin="round"/>`;
    (o.labels || []).forEach(([x, y, t, sz, wt]) => { s += `<text x="${x}" y="${y}" font-family="Manrope" font-size="${sz || 12}" font-weight="${wt || 500}" fill="${c.label}" text-anchor="middle" stroke="${c.land}" stroke-width="3" paint-order="stroke">${t}</text>`; });
    // extra coloured routes (trip report)
    (o.routes || []).forEach(rt => {
      const d = smooth(rt.pts);
      s += `<path d="${d}" fill="none" stroke="${c.routeCase}" stroke-width="${(rt.width || 5) + 3.5}" stroke-linecap="round" stroke-linejoin="round" opacity=".95"/>`;
      s += `<path d="${d}" fill="none" stroke="${rt.color}" stroke-width="${rt.width || 5}" stroke-linecap="round" stroke-linejoin="round" ${rt.dash ? `stroke-dasharray="${rt.dash}"` : ''}/>`;
    });
    if (o.route && o.showRoute !== false) {
      const d = smooth(o.route);
      s += `<path d="${d}" fill="none" stroke="${c.routeCase}" stroke-width="10" stroke-linecap="round" stroke-linejoin="round"/>`;
      s += `<path class="routeLine" d="${d}" fill="none" stroke="${c.route}" stroke-width="6" stroke-linecap="round" stroke-linejoin="round"/>`;
    } else if (o.route) {
      s += `<path class="routeLine" d="${smooth(o.route)}" fill="none" stroke="none"/>`;
    }
    s += `</svg><div class="layer"></div>`;
    el.classList.add('map'); el.innerHTML = s;
    return { svg: el.querySelector('svg'), layer: el.querySelector('.layer'), path: el.querySelector('.routeLine') };
  }

  /* ---------- 3D bike markers (real asset layers) ---------- */
  const imgCache = {};
  const pending = [];
  function img(src) {
    if (!imgCache[src]) imgCache[src] = new Promise((res, rej) => { const i = new Image(); i.onload = () => res(i); i.onerror = () => rej(new Error('img ' + src)); i.src = src; });
    return imgCache[src];
  }
  async function drawBike(cv, shCv, type, n, color) {
    const base = `assets/bikes/${type}_${n}_`;
    const [b, p, g, sh] = await Promise.all(['base', 'paint', 'gloss', 'shadow'].map(l => img(base + l + '.png')));
    const W = b.width, H = b.height; cv.width = W; cv.height = H; const x = cv.getContext('2d');
    x.drawImage(b, 0, 0);
    const t = document.createElement('canvas'); t.width = W; t.height = H; const tx = t.getContext('2d');
    tx.drawImage(p, 0, 0); tx.globalCompositeOperation = 'multiply'; tx.fillStyle = color; tx.fillRect(0, 0, W, H);
    tx.globalCompositeOperation = 'destination-in'; tx.drawImage(p, 0, 0);
    x.drawImage(t, 0, 0); x.drawImage(g, 0, 0);
    if (shCv) { shCv.width = W; shCv.height = H; shCv.getContext('2d').drawImage(sh, 0, 0); }
  }
  function hexA(hex, a) { const n = parseInt(hex.slice(1), 16); return `rgba(${n >> 16},${(n >> 8) & 255},${n & 255},${a})`; }

  /* rider(layer, {x,y,rot,type,n,color,size,name,role,roleColor,tag:'below'|'above'|'left'|'right'|'none', halo:true}) */
  function rider(layer, o) {
    const S = o.size || 50; const d = document.createElement('div'); d.className = 'rider'; d.style.left = o.x + 'px'; d.style.top = o.y + 'px';
    if (o.halo !== false) {
      const h = document.createElement('div'); h.className = 'halo'; const hs = S * (o.haloScale || 0.95); h.style.width = hs + 'px'; h.style.height = hs + 'px';
      h.style.background = `radial-gradient(circle, ${hexA(o.color, .34)} 0%, ${hexA(o.color, .20)} 45%, ${hexA(o.color, 0)} 70%)`;
      h.style.border = `${Math.max(1.2, S / 40)}px solid ${hexA(o.color, .45)}`; d.appendChild(h);
    }
    const sh = document.createElement('canvas'); sh.className = 'bk'; const bk = document.createElement('canvas'); bk.className = 'bk';
    for (const [c, dx, dy, op] of [[sh, S * 0.06, S * 0.09, 0.55], [bk, 0, 0, 1]]) {
      c.style.width = S + 'px'; c.style.height = S + 'px'; c.style.left = (-S / 2 + dx) + 'px'; c.style.top = (-S / 2 + dy) + 'px';
      c.style.transform = `rotate(${o.rot || 0}deg)`; c.style.opacity = op; d.appendChild(c);
    }
    pending.push(drawBike(bk, sh, o.type, o.n || 1, o.color));
    if (o.name && o.tag !== 'none') {
      const t = document.createElement('div'); t.className = 'tag' + (o.role ? '' : ' noRole');
      t.innerHTML = (o.role ? `<span class="role" style="background:${o.roleColor || o.color}">${o.role}</span>` : `<span class="dot" style="background:${o.color};width:10px;height:10px"></span>`) + o.name + (o.extra || '');
      const off = S * (o.tagOff || 0.36) + 4; const pos = o.tag || 'below';
      if (pos === 'below') t.style.top = off + 'px';
      if (pos === 'above') { t.style.top = -(off + 24) + 'px'; }
      if (pos === 'right') { t.style.top = '-12px'; t.style.left = off + 'px'; t.style.transform = 'none'; }
      if (pos === 'left') { t.style.top = '-12px'; t.style.right = off + 'px'; t.style.transform = 'none'; }
      d.appendChild(t);
    }
    layer.appendChild(d); return d;
  }
  /* place a rider at fraction f of path, heading along it */
  function onPath(path, f, back) {
    const L = path.getTotalLength(); const a = path.getPointAtLength(L * f); const b = path.getPointAtLength(Math.min(L, L * f + 2)); const a2 = path.getPointAtLength(Math.max(0, L * f - 2));
    let dx = b.x - a2.x, dy = b.y - a2.y; if (back) { dx = -dx; dy = -dy; }
    return { x: a.x, y: a.y, rot: (Math.atan2(dx, -dy) * 180) / Math.PI };
  }

  function atY(path, y) {
    const L = path.getTotalLength(); let best = 0, bd = 1e9;
    for (let i = 0; i <= 400; i++) { const p = path.getPointAtLength(L * i / 400); const d = Math.abs(p.y - y); if (d < bd) { bd = d; best = i / 400; } }
    return best;
  }
  /* ---------- icons ---------- */
  const CUSTOM = {
    earbuds: '<g fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"><circle cx="7" cy="7.5" r="4"/><path d="M9 10.9V19a1.6 1.6 0 0 1-3.2 0v-7.7"/><circle cx="7" cy="7.5" r="1.3" fill="currentColor" stroke="none"/><circle cx="17" cy="7.5" r="4"/><path d="M15 10.9V19a1.6 1.6 0 0 0 3.2 0v-7.7"/><circle cx="17" cy="7.5" r="1.3" fill="currentColor" stroke="none"/></g>',
    siren: '<g fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"><path d="M6.5 18v-5.5a5.5 5.5 0 0 1 11 0V18"/><path d="M4 18h16v2.5H4z"/><path d="M12 3v2M4.2 6.2l1.4 1.4M19.8 6.2l-1.4 1.4M2.5 12h1.5M20 12h1.5"/><path d="M10 12.5a2 2 0 0 1 2-2"/></g>',
    signal: '<g fill="currentColor"><rect x="3" y="15" width="3" height="5" rx="1"/><rect x="8" y="11" width="3" height="9" rx="1"/><rect x="13" y="7" width="3" height="13" rx="1"/><rect x="18" y="3" width="3" height="17" rx="1"/></g>',
    battery: '<g><rect x="2.5" y="7" width="17" height="10" rx="2.5" fill="none" stroke="currentColor" stroke-width="1.6"/><rect x="4.5" y="9" width="11" height="6" rx="1.2" fill="currentColor"/><rect x="20.5" y="10" width="1.8" height="4" rx=".9" fill="currentColor"/></g>',
    wifi: '<g fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><path d="M3 9.5a13 13 0 0 1 18 0"/><path d="M6.5 13a8 8 0 0 1 11 0"/><path d="M10 16.5a3 3 0 0 1 4 0"/></g>',
    back: '<g fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round"><path d="M19 12H5"/><path d="m11 6-6 6 6 6"/></g>',
    more: '<g fill="currentColor"><circle cx="12" cy="5.5" r="1.7"/><circle cx="12" cy="12" r="1.7"/><circle cx="12" cy="18.5" r="1.7"/></g>',
    plus: '<g fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round"><path d="M12 5v14M5 12h14"/></g>',
    chev: '<g fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round"><path d="m9 6 6 6-6 6"/></g>',
    nav: '<g fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"><path d="M12 3 19 20l-7-4-7 4z"/></g>',
    volume: '<g fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"><path d="M4 9.5h3.5L12 5.5v13l-4.5-4H4z"/><path d="M15.5 9a4 4 0 0 1 0 6M18 6.5a7.5 7.5 0 0 1 0 11"/></g>',
    person: '<g fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="8" r="3.6"/><path d="M4.5 20a7.5 7.5 0 0 1 15 0"/></g>',
    home: '<g fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"><path d="M4 11 12 4l8 7"/><path d="M6 9.5V20h12V9.5"/></g>',
    poll: '<g fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round"><path d="M5 20V11M12 20V5M19 20v-6"/></g>',
    share: '<g fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"><circle cx="18" cy="5.5" r="2.5"/><circle cx="6" cy="12" r="2.5"/><circle cx="18" cy="18.5" r="2.5"/><path d="m8.2 10.8 7.6-4M8.2 13.2l7.6 4"/></g>',
    link: '<g fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"><path d="M10 14a4 4 0 0 0 5.7 0l3-3a4 4 0 0 0-5.7-5.7l-1 1"/><path d="M14 10a4 4 0 0 0-5.7 0l-3 3a4 4 0 0 0 5.7 5.7l1-1"/></g>',
    phone: '<g fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"><path d="M5 4h4l2 5-2.5 1.5a11 11 0 0 0 5 5L15 13l5 2v4a1 1 0 0 1-1 1A16 16 0 0 1 4 5a1 1 0 0 1 1-1z"/></g>',
    bell: '<g fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"><path d="M6 16V11a6 6 0 0 1 12 0v5l1.5 2h-15z"/><path d="M10 20.5a2 2 0 0 0 4 0"/></g>',
    gauge: '<g fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"><path d="M4.5 17a8.5 8.5 0 1 1 15 0"/><path d="m12 13 4-4.5"/><circle cx="12" cy="13.5" r="1.2"/></g>',
  };
  function icon(name, size = 22, color) {
    const st = `width:${size}px;height:${size}px;${color ? 'color:' + color : ''}`;
    if (CUSTOM[name]) return `<svg class="i" viewBox="0 0 24 24" style="${st}">${CUSTOM[name]}</svg>`;
    return `<svg class="i" style="${st}"><use href="assets/icons.svg#i-${name}"/></svg>`;
  }
  function chrome(screen, opts = {}) {
    const st = document.createElement('div'); st.className = 'status'; if (opts.light) st.style.color = '#fff';
    st.innerHTML = `<span>${opts.time || '7:42'}</span><span class="cam"></span><span class="ic">${icon('signal', 14)}${icon('wifi', 15)}${icon('battery', 19)}</span>`;
    screen.appendChild(st);
    const g = document.createElement('div'); g.className = 'gesture'; screen.appendChild(g);
  }

  /* ---------- panel background decoration ---------- */
  function deco(panel, kind) {
    const W = panel.offsetWidth, H = panel.offsetHeight; const r = rng(kind === 'teal' ? 11 : 23);
    const line = kind === 'teal' ? 'rgba(255,255,255,.055)' : 'rgba(43,122,140,.07)';
    const route = kind === 'teal' ? 'rgba(255,255,255,.16)' : 'rgba(43,122,140,.18)';
    let s = `<svg class="deco" width="${W}" height="${H}" viewBox="0 0 ${W} ${H}" xmlns="http://www.w3.org/2000/svg">`;
    // soft topographic contours
    for (let k = 0; k < 2; k++) {
      const cx = k ? W * 0.95 : W * 0.02, cy = k ? H * 0.22 : H * 0.78;
      for (let i = 1; i < 14; i++) {
        const pts = []; const R = i * 58; for (let j = 0; j < 12; j++) { const a = (j / 12) * Math.PI * 2; const rr = R * (0.88 + 0.22 * Math.sin(a * 3 + k + i * 0.3)); pts.push([cx + Math.cos(a) * rr, cy + Math.sin(a) * rr * 0.75]); }
        s += `<path d="${smooth(pts, true)}" fill="none" stroke="${line}" stroke-width="2"/>`;
      }
    }
    // dashed route motif sweeping behind the phone
    const rp = [[-40, H * 0.58], [W * 0.18, H * 0.47], [W * 0.5, H * 0.52], [W * 0.82, H * 0.40], [W + 40, H * 0.30]];
    s += `<path d="${smooth(rp)}" fill="none" stroke="${route}" stroke-width="22" stroke-linecap="round"/>`;
    s += `<path d="${smooth(rp)}" fill="none" stroke="${kind === 'teal' ? 'rgba(255,255,255,.22)' : 'rgba(43,122,140,.22)'}" stroke-width="3" stroke-dasharray="14 16" stroke-linecap="round"/>`;
    s += '</svg>';
    panel.insertAdjacentHTML('afterbegin', s);
  }

  window.CR = { ICONS: CUSTOM, makeMap, rider, onPath, atY, icon, chrome, deco, smooth, MEMBERS, hexA, rng,
    ready: async function (fn) {
      await document.fonts.ready;
      try { if (fn) await fn(); } catch (e) { console.error(e); window.__err = String(e); }
      await Promise.all(pending).catch(e => { window.__err = String(e); });
      await document.fonts.ready; await new Promise(r => requestAnimationFrame(() => requestAnimationFrame(r)));
      window.__ready = true;
    } };
})();
