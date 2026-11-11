/* Cockpit (ride map) screen, shared by phone panels 1 and 10. buildCockpit(screenEl, {dark}) */
(function () {
  const css = `
.ck .topcard{position:absolute;left:14px;right:14px;top:40px;padding:12px 14px;display:flex;align-items:center;gap:12px;z-index:6}
.ck .topcard .ic{width:40px;height:40px;border-radius:12px;background:var(--primarySoft);color:var(--primary);display:flex;align-items:center;justify-content:center}
.ck .fab{position:absolute;right:14px;width:46px;height:46px;border-radius:14px;display:flex;align-items:center;justify-content:center;color:var(--text);z-index:6}
.ck .speed{position:absolute;right:14px;bottom:200px;width:92px;height:84px;display:flex;flex-direction:column;align-items:center;justify-content:center;z-index:6}
.ck .speed b{font-size:36px;font-weight:700;line-height:1}
.ck .limit{position:absolute;right:116px;bottom:200px;width:72px;height:84px;display:flex;flex-direction:column;align-items:center;justify-content:center;gap:3px;z-index:6}
.ck .limit .ring{width:42px;height:42px;border-radius:50%;border:4px solid var(--primary);display:flex;align-items:center;justify-content:center;font-weight:700;font-size:16px;background:var(--surface)}
.ck .ridebar{position:absolute;left:0;right:0;bottom:0;height:188px;background:var(--surface);border-radius:20px 20px 0 0;box-shadow:0 -4px 16px var(--shadow);padding:10px 18px 26px;z-index:7}
.ck .handle{width:36px;height:4px;border-radius:2px;background:var(--borderStrong);margin:0 auto 12px}
.ck .next{display:flex;align-items:center;gap:12px;padding:10px 12px;border-radius:12px;background:var(--surfaceAlt)}
.ck .actions{display:flex;gap:10px;margin-top:14px}
.ck .actions .talk{flex:1.25;height:56px;border-radius:14px}
.ck .actions .sosb{flex:.75;height:56px;border-radius:14px;font-size:18px;letter-spacing:.5px}
.ck .actions .sq{width:56px;height:56px;border-radius:14px;background:var(--surfaceAlt);display:flex;align-items:center;justify-content:center;color:var(--text)}`;
  window.buildCockpit = function (scr, o = {}) {
    if (!document.getElementById('ckcss')) { const st = document.createElement('style'); st.id = 'ckcss'; st.textContent = css; document.head.appendChild(st); }
    const I = CR.icon; scr.classList.add('ck'); if (o.dark) scr.classList.add('dark');
    scr.innerHTML = `<div class="mapbox" style="position:absolute;inset:0"></div>
    <div class="topcard float"><div class="ic">${I('route', 22)}</div>
      <div style="flex:1;min-width:0"><div class="title">Nandi Hills sunrise ride</div><div class="label" style="display:flex;align-items:center;gap:6px"><span style="width:8px;height:8px;border-radius:4px;background:var(--success)"></span>5 riders · group together</div></div>
      <div style="color:var(--muted)">${I('more', 22)}</div></div>
    <div class="fab float" style="top:122px">${I('location', 22)}</div>
    <div class="fab float" style="top:176px">${I(o.dark ? 'moon' : 'map', 22)}</div>
    <div class="speed float"><b>42</b><span class="caption">km/h</span></div>
    <div class="limit float"><div class="ring">60</div><span class="caption">Limit</span></div>
    <div class="ridebar"><div class="handle"></div>
      <div class="next">${I('fuel', 22, 'var(--accent)')}<div style="flex:1"><div style="font-size:14px;font-weight:600">Next stop · Fuel, Devanahalli</div><div class="caption">12 km · about 18 min</div></div><span style="color:var(--muted)">${I('chev', 20)}</span></div>
      <div class="actions"><div class="btn primary talk">${I('mic', 22)}Hold to talk</div><div class="btn sos sosb">SOS</div><div class="sq">${I('users', 22)}</div></div>
    </div>`;
    CR.chrome(scr);
    const m = CR.makeMap(scr.querySelector('.mapbox'), {
      w: 412, h: 898, seed: 5, dark: !!o.dark, gridAngle: 18, gridStep: 44,
      route: [[190, 960], [214, 800], [150, 660], [178, 540], [252, 430], [262, 320], [196, 220], [214, 110], [270, -40]],
      major: [[[-20, 380], [120, 400], [262, 440], [430, 520]]],
      towns: [[330, 640, 110], [80, 230, 90]], parks: [[60, 520, 50], [350, 300, 42]], lake: [380, 120, 46],
      river: [[-20, 760], [90, 740], [200, 770], [330, 735], [440, 760]], riverW: 14,
      labels: [[66, 168, 'Devanahalli', 13, 600], [345, 600, 'Vijayapura', 12, 600], [70, 460, 'NH 44', 11, 600]],
      country: 6,
    });
    const C = CR.MEMBERS[o.dark ? 'dark' : 'light'];
    const riders = [
      { y: 175, type: 'adventure', n: 1, color: C[0], name: 'Asha', role: 'L', tag: 'right' },
      { y: 285, type: 'sport', n: 1, color: C[4], name: 'Kiran', tag: 'left' },
      { y: 400, type: 'cruiser', n: 2, color: C[3], name: 'Arjun', tag: 'right', extra: '<span style="font-weight:500;color:var(--muted)">+ pillion</span>' },
      { y: 505, type: 'retro', n: 1, color: C[7], name: 'Meera', tag: 'left' },
      { y: 605, type: 'offroad', n: 1, color: C[1], name: 'Ravi', role: 'S', tag: 'right' },
    ];
    riders.forEach(r => { const p = CR.onPath(m.path, CR.atY(m.path, r.y)); CR.rider(m.layer, { ...p, ...r, size: 86 }); });
  };
})();
