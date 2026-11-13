/* CoRoute homepage hero: a live 3D mountain road with a riding convoy (lead in front, sweeper at the back).
   Hand-written WebGL 1 (no library, about 8 KB gzip). Loaded late by home.js, only when the visitor does not ask
   for reduced motion. The scene is endless, like a looping video: terrain, road and riders are computed from the
   same height functions in the shaders and here, around a camera that rides behind the group.
   Power: device pixel ratio capped at 1.5, display rate (60 fps) by default and a 30 fps cap as soon as the device
   cannot keep up, a coarser terrain grid on small screens, 4 draw calls a frame, paused when the hero is off
   screen or the tab is hidden. Day and night follow the site theme. If WebGL is missing or the context is lost,
   the static illustration underneath simply stays. No network requests.
   To tweak: see "Tuning" just below (speed, number of riders, spacing, marker style). */
(function () {
  'use strict';
  var doc = document, win = window, root = doc.documentElement;
  var host = doc.querySelector('[data-hero3d]');
  if (!host || host.getAttribute('data-state') === 'live') return;

  function fail(reason) { host.setAttribute('data-state', 'fallback'); host.setAttribute('data-reason', reason); }

  var canvas = doc.createElement('canvas');
  canvas.className = 'hero3d__canvas';
  canvas.setAttribute('aria-hidden', 'true');
  var glOpts = { antialias: true, alpha: false, depth: true, stencil: false, powerPreference: 'low-power', preserveDrawingBuffer: false };
  var gl = null;
  try { gl = canvas.getContext('webgl', glOpts) || canvas.getContext('experimental-webgl', glOpts); } catch (e) { gl = null; }
  if (!gl) { fail('no-webgl'); return; }
  var deriv = gl.getExtension('OES_standard_derivatives');

  var small = Math.min(win.innerWidth || 1024, win.screen ? win.screen.width : 1024) < 760;
  var coarse = win.matchMedia ? win.matchMedia('(pointer: coarse)').matches : false;
  var mobile = small || coarse;
  /* ---------- Tuning (docs/quality/ROUND7_WEBSITE_NOTES.md) ---------- */
  var SPEED = 8.5;                                 // how fast the group rides (m/s); 8.5 is a calm touring pace
  var RIDERS = 6;                                  // riders in the group, 2 to 8 (first is the lead, last the sweeper)
  var GAP = 7.2;                                   // metres between riders
  var NEAREST = 30;                                // metres from the camera to the sweeper
  var MARKERS = 'bike';                            // 'bike': riders seen from behind; 'dot': the round map markers
  var SLOW_FRAME_MS = 24;                          // average frame time above this drops the scene to 30 fps

  var FRAME_MS = 0;                                // 0: display rate; set to 1000 / 30 when the device is slow
  var DPR_CAP = 1.5;
  var GRID = mobile ? 2.6 : 1.6;                   // terrain grid spacing (m)
  var HALF_W = mobile ? 90 : 120;                  // terrain half width (m)
  var DEPTH = mobile ? 230 : 300;                  // terrain depth ahead of the camera (m)
  var BEHIND = 24;
  var ROAD_W = 3.3;

  /* ---------- The world: the same functions as the GLSL below ---------- */
  function roadX(z) { return 14.0 * Math.sin(z * 0.022) + 6.0 * Math.sin(z * 0.053 + 1.0); }
  function roadH(z) { return 3.0 * Math.sin(z * 0.011) + 1.5 * Math.sin(z * 0.031 + 2.0); }
  function smooth(a, b, v) { var t = Math.max(0, Math.min(1, (v - a) / (b - a))); return t * t * (3 - 2 * t); }
  function mount(x, z) {
    var a = Math.sin(x * 0.045 + z * 0.013) * Math.sin(z * 0.021 - x * 0.017 + 0.7);
    var b = 1.0 - Math.abs(Math.sin(x * 0.07 - z * 0.035 + 1.3));
    var c = Math.sin(x * 0.19 + z * 0.15) * 0.5 + 0.5;
    return 9.0 * a + 8.0 * b + 2.2 * c;
  }
  function height(x, z) {
    var d = Math.abs(x - roadX(z));
    return roadH(z) - 0.25 + smooth(5.0, 40.0, d) * (mount(x, z) + 2.0 + d * 0.24);
  }
  var GLSL_WORLD = [
    'float roadX(float z){ return 14.0*sin(z*0.022) + 6.0*sin(z*0.053+1.0); }',
    'float roadH(float z){ return 3.0*sin(z*0.011) + 1.5*sin(z*0.031+2.0); }',
    'float mount(float x, float z){',
    '  float a = sin(x*0.045 + z*0.013)*sin(z*0.021 - x*0.017 + 0.7);',
    '  float b = 1.0 - abs(sin(x*0.07 - z*0.035 + 1.3));',
    '  float c = sin(x*0.19 + z*0.15)*0.5 + 0.5;',
    '  return 9.0*a + 8.0*b + 2.2*c;',
    '}',
    'float height(float x, float z){',
    '  float d = abs(x - roadX(z));',
    '  return roadH(z) - 0.25 + smoothstep(5.0, 40.0, d)*(mount(x,z) + 2.0 + d*0.24);',
    '}'
  ].join('\n');

  /* ---------- Shaders ---------- */
  var SKY_VS = 'attribute vec2 aP; varying float vY; void main(){ vY = aP.y*0.5+0.5; gl_Position = vec4(aP,0.999,1.0); }';
  var SKY_FS = 'precision mediump float; varying float vY; uniform vec3 uTop; uniform vec3 uHor; uniform float uHorY;' +
    'void main(){ float t = smoothstep(uHorY-0.05, 1.0, vY); gl_FragColor = vec4(mix(uHor, uTop, t), 1.0); }';

  var TERRAIN_VS = [
    'precision highp float;',
    'attribute vec2 aG;',
    'uniform vec2 uO; uniform mat4 uVP; uniform vec3 uCam; uniform vec2 uFogR;',
    'varying vec3 vN; varying float vH; varying float vFog; varying float vD;',
    GLSL_WORLD,
    'void main(){',
    '  float x = aG.x + uO.x; float z = aG.y + uO.y;',
    '  float h = height(x, z);',
    '  float e = 0.7;',
    '  float hx = height(x+e, z) - height(x-e, z);',
    '  float hz = height(x, z+e) - height(x, z-e);',
    '  vN = normalize(vec3(-hx, 2.0*e, -hz));',
    '  vH = h; vD = abs(x - roadX(z));',
    '  vec3 p = vec3(x, h, z);',
    '  vFog = smoothstep(uFogR.x, uFogR.y, length(p - uCam));',
    '  gl_Position = uVP * vec4(p, 1.0);',
    '}'
  ].join('\n');
  var TERRAIN_FS = [
    deriv ? '#extension GL_OES_standard_derivatives : enable' : '',
    'precision mediump float;',
    'varying vec3 vN; varying float vH; varying float vFog; varying float vD;',
    'uniform vec3 uLow; uniform vec3 uHigh; uniform vec3 uFog; uniform vec3 uSun; uniform vec3 uLine; uniform float uAmb; uniform float uLineA;',
    'void main(){',
    '  vec3 n = normalize(vN);',
    '  float diff = max(dot(n, uSun), 0.0);',
    '  float t = clamp((vH + 1.0) / 30.0, 0.0, 1.0);',
    '  vec3 base = mix(uLow, uHigh, t);',
    '  vec3 col = base * (uAmb + (1.0 - uAmb) * diff);',
    '  float f = fract(vH / 2.4); float dd = min(f, 1.0 - f);',
    deriv ? '  float w = fwidth(vH / 2.4) * 1.1;' : '  float w = 0.06;',
    '  float line = 1.0 - smoothstep(0.0, w + 0.001, dd);',
    '  line *= smoothstep(5.0, 11.0, vD) * (1.0 - vFog);',
    '  col = mix(col, uLine, line * uLineA);',
    '  gl_FragColor = vec4(mix(col, uFog, vFog), 1.0);',
    '}'
  ].join('\n');

  var ROAD_VS = [
    'precision highp float;',
    'attribute vec2 aR;', // x: distance along (m), y: side -1..1
    'uniform float uZ0; uniform mat4 uVP; uniform vec3 uCam; uniform vec2 uFogR; uniform float uW;',
    'varying vec2 vUv; varying float vFog;',
    GLSL_WORLD,
    'void main(){',
    '  float z = uZ0 - aR.x;',
    '  vec3 p = vec3(roadX(z) + aR.y * uW, roadH(z) + 0.04, z);',
    '  vUv = vec2(aR.y, z);',
    '  vFog = smoothstep(uFogR.x, uFogR.y, length(p - uCam));',
    '  gl_Position = uVP * vec4(p, 1.0);',
    '}'
  ].join('\n');
  var ROAD_FS = [
    'precision highp float;',
    'varying vec2 vUv; varying float vFog;',
    'uniform vec3 uRoad; uniform vec3 uEdge; uniform vec3 uRoute; uniform vec3 uDash; uniform vec3 uFog; uniform vec2 uConvoy;',
    'void main(){',
    '  float s = abs(vUv.x);',
    '  vec3 col = uRoad;',
    '  col = mix(col, uEdge, smoothstep(0.86, 0.9, s) * (1.0 - smoothstep(0.95, 0.99, s)));',
    '  float inConvoy = step(uConvoy.y, vUv.y) * step(vUv.y, uConvoy.x);',
    '  float route = 1.0 - smoothstep(0.1, 0.16, s);',
    '  col = mix(col, uRoute, route * (0.55 + 0.45 * inConvoy));',
    '  float dash = step(0.5, fract(vUv.y / 5.0)) * (1.0 - smoothstep(0.025, 0.045, s));',
    '  col = mix(col, uDash, dash * 0.9);',
    '  gl_FragColor = vec4(mix(col, uFog, vFog), 1.0);',
    '}'
  ].join('\n');

  var RIDER_VS = [
    'precision highp float;',
    'attribute vec3 aP; attribute vec3 aC; attribute vec2 aFx;', // aFx: x ping phase 0..1 (0 = none), y lean (rad)
    'uniform mat4 uVP; uniform float uScale;',
    'varying vec3 vC; varying float vPulse; varying float vLean; varying float vPx;',
    'void main(){',
    '  vec4 c = uVP * vec4(aP, 1.0);',
    '  gl_Position = c;',
    '  float size = clamp(uScale / max(c.w, 1.0), 14.0, 128.0);',
    '  gl_PointSize = size;',
    '  vC = aC; vPulse = aFx.x; vLean = aFx.y; vPx = 2.0 / size;',
    '}'
  ].join('\n');
  /* One point sprite per rider. uBike 1: a rider seen from behind (rear tyre, handlebar, jacket in the member
     colour, helmet, tail light) leaning into the bends, with a shadow and the "position update" ping on the road.
     uBike 0: the round map marker. */
  var RIDER_FS = [
    'precision mediump float;',
    'varying vec3 vC; varying float vPulse; varying float vLean; varying float vPx;',
    'uniform vec3 uRing; uniform vec3 uTyre; uniform float uGlow; uniform float uBike;',
    'float box(vec2 p, vec2 b, float r){ vec2 d = abs(p) - b + r; return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0) - r; }',
    'void main(){',
    '  vec2 q = vec2(gl_PointCoord.x * 2.0 - 1.0, 1.0 - gl_PointCoord.y * 2.0);',
    '  if (uBike < 0.5) {',
    '    float r = length(q);',
    '    if (r > 1.0) discard;',
    '    float core = 1.0 - smoothstep(0.24, 0.27, r);',
    '    float ring = (1.0 - smoothstep(0.32, 0.35, r)) * (1.0 - core);',
    '    float halo = (1.0 - smoothstep(0.3, 1.0, r)) * uGlow;',
    '    float pr = 0.3 + vPulse * 0.68;',
    '    float pulse = (1.0 - smoothstep(0.0, 0.05, abs(r - pr))) * (1.0 - vPulse) * step(0.001, vPulse);',
    '    vec3 col = vC * core + uRing * ring + vC * pulse;',
    '    float a = max(max(core, ring), max(halo * 0.55, pulse * 0.9));',
    '    if (a < 0.01) discard;',
    '    gl_FragColor = vec4(core + ring > 0.0 ? col : vC, a);',
    '    return;',
    '  }',
    '  float aa = vPx * 1.4;',
    '  vec2 g = vec2(q.x, (q.y + 0.56) * 2.8);', // the road under the tyre, flattened by the view angle
    '  float gr = length(g);',
    '  float shadow = (1.0 - smoothstep(0.1, 0.46, gr)) * 0.34;',
    '  float pr = 0.22 + vPulse * 0.72;',
    '  float pulse = (1.0 - smoothstep(0.0, 0.07, abs(gr - pr))) * (1.0 - vPulse) * step(0.001, vPulse);',
    '  vec2 p = q + vec2(0.0, 0.56);',
    '  float cs = cos(vLean); float sn = sin(vLean);',
    '  p = vec2(cs * p.x - sn * p.y, sn * p.x + cs * p.y);',
    '  float tyre = min(box(p - vec2(0.0, 0.21), vec2(0.07, 0.21), 0.07), box(p - vec2(0.0, 0.5), vec2(0.27, 0.03), 0.03));',
    '  float torso = box(p - vec2(0.0, 0.62), vec2(0.175, 0.2), 0.1);',
    '  float helmet = length(p - vec2(0.0, 0.93)) - 0.13;',
    '  float tail = length(p - vec2(0.0, 0.4));',
    '  float rim = min(min(tyre, torso), helmet) - 0.035;',
    '  vec3 col = vec3(0.0); float a = shadow; float m;',
    '  m = pulse * 0.9; col = mix(col, vC, m); a = max(a, m);',
    '  m = (1.0 - smoothstep(0.0, 0.5, tail)) * uGlow; col = mix(col, vec3(0.92, 0.2, 0.14), m); a = max(a, m * 0.7);',
    '  m = 1.0 - smoothstep(-aa, aa, rim); col = mix(col, uRing, m); a = max(a, m);',
    '  m = 1.0 - smoothstep(-aa, aa, tyre); col = mix(col, uTyre, m);',
    '  m = 1.0 - smoothstep(-aa, aa, torso); col = mix(col, vC, m);',
    '  m = 1.0 - smoothstep(-aa, aa, helmet); col = mix(col, mix(vC, vec3(0.97), 0.62), m);',
    '  m = 1.0 - smoothstep(-aa, aa, tail - 0.052); col = mix(col, vec3(0.93, 0.22, 0.16), m);',
    '  if (a < 0.01) discard;',
    '  gl_FragColor = vec4(col, a);',
    '}'
  ].join('\n');

  function shader(type, src) {
    var s = gl.createShader(type);
    gl.shaderSource(s, src);
    gl.compileShader(s);
    if (!gl.getShaderParameter(s, gl.COMPILE_STATUS)) throw new Error(gl.getShaderInfoLog(s) || 'shader');
    return s;
  }
  function program(vs, fs, attrs, unis) {
    var p = gl.createProgram();
    gl.attachShader(p, shader(gl.VERTEX_SHADER, vs));
    gl.attachShader(p, shader(gl.FRAGMENT_SHADER, fs));
    gl.linkProgram(p);
    if (!gl.getProgramParameter(p, gl.LINK_STATUS)) throw new Error(gl.getProgramInfoLog(p) || 'link');
    var o = { p: p, a: {}, u: {} };
    attrs.forEach(function (n) { o.a[n] = gl.getAttribLocation(p, n); });
    unis.forEach(function (n) { o.u[n] = gl.getUniformLocation(p, n); });
    return o;
  }

  var sky, terrain, road, riders;
  try {
    sky = program(SKY_VS, SKY_FS, ['aP'], ['uTop', 'uHor', 'uHorY']);
    terrain = program(TERRAIN_VS, TERRAIN_FS, ['aG'], ['uO', 'uVP', 'uCam', 'uFogR', 'uLow', 'uHigh', 'uFog', 'uSun', 'uLine', 'uAmb', 'uLineA']);
    road = program(ROAD_VS, ROAD_FS, ['aR'], ['uZ0', 'uVP', 'uCam', 'uFogR', 'uW', 'uRoad', 'uEdge', 'uRoute', 'uDash', 'uFog', 'uConvoy']);
    riders = program(RIDER_VS, RIDER_FS, ['aP', 'aC', 'aFx'], ['uVP', 'uScale', 'uRing', 'uTyre', 'uGlow', 'uBike']);
  } catch (e) { fail('shader'); return; }

  /* ---------- Geometry ---------- */
  function buffer(data, target) {
    var b = gl.createBuffer();
    gl.bindBuffer(target || gl.ARRAY_BUFFER, b);
    gl.bufferData(target || gl.ARRAY_BUFFER, data, gl.STATIC_DRAW);
    return b;
  }
  var skyBuf = buffer(new Float32Array([-1, -1, 3, -1, -1, 3]));

  var nx = Math.round(HALF_W * 2 / GRID) + 1, nz = Math.round((DEPTH + BEHIND) / GRID) + 1;
  var grid = new Float32Array(nx * nz * 2);
  for (var j = 0, k = 0; j < nz; j++) for (var i = 0; i < nx; i++) { grid[k++] = -HALF_W + i * GRID; grid[k++] = -j * GRID; }
  var idx = new Uint16Array((nx - 1) * (nz - 1) * 6);
  for (var jj = 0, q = 0; jj < nz - 1; jj++) for (var ii = 0; ii < nx - 1; ii++) {
    var a = jj * nx + ii, b = a + 1, c = a + nx, d = c + 1;
    idx[q++] = a; idx[q++] = c; idx[q++] = b; idx[q++] = b; idx[q++] = c; idx[q++] = d;
  }
  var gridBuf = buffer(grid), idxBuf = buffer(idx, gl.ELEMENT_ARRAY_BUFFER), idxCount = idx.length;

  var ROAD_STEP = 1.0, roadN = Math.round((DEPTH + BEHIND) / ROAD_STEP) + 1;
  var roadArr = new Float32Array(roadN * 4);
  for (var r = 0; r < roadN; r++) { roadArr[r * 4] = r * ROAD_STEP; roadArr[r * 4 + 1] = -1; roadArr[r * 4 + 2] = r * ROAD_STEP; roadArr[r * 4 + 3] = 1; }
  var roadBuf = buffer(roadArr);

  /* The convoy, lead first: distance ahead of the camera (m), lane offset (a staggered formation), colour index,
     a little breathing in the gaps. */
  var COLOURS = [7, 1, 2, 3, 0, 4, 5, 6];
  var CONVOY = [];
  var nRiders = Math.max(2, Math.min(8, RIDERS));
  for (var ci = 0; ci < nRiders; ci++) {
    CONVOY.push({ ahead: NEAREST + (nRiders - 1 - ci) * GAP, lane: ci % 2 ? -1.3 : -0.5, c: COLOURS[ci], ph: (ci * 1.7) % 6.28 });
  }
  var BIKE = MARKERS === 'bike';
  var LEAN = 14;                                   // how hard riders lean in bends (0: upright)
  var riderArr = new Float32Array(CONVOY.length * 8);
  var riderBuf = gl.createBuffer();

  /* ---------- Palettes: the app's light and dark tokens ---------- */
  function hex(h) { var n = parseInt(h.slice(1), 16); return [(n >> 16 & 255) / 255, (n >> 8 & 255) / 255, (n & 255) / 255]; }
  var DAY = {
    top: hex('#D3E6E8'), hor: hex('#F3F1EC'), fog: hex('#F1EFEA'), low: hex('#DCE6E0'), high: hex('#93ABA6'), sun: [0.55, 0.7, 0.35],
    line: hex('#2B7A8C'), lineA: 0.26, amb: 0.5, road: hex('#4A5058'), edge: hex('#CFC8BD'), route: hex('#2B7A8C'), dash: hex('#F6F4F0'),
    ring: hex('#FFFFFF'), tyre: hex('#22262B'), glow: 0.25,
    members: ['#2B7A8C', '#3E8E5E', '#B9821C', '#B5577A', '#3D7BC8', '#7E6BB0', '#2F8577', '#D9822B'].map(hex)
  };
  var NIGHT = {
    top: hex('#121519'), hor: hex('#1D3036'), fog: hex('#171B20'), low: hex('#1E242A'), high: hex('#323A44'), sun: [-0.35, 0.75, 0.3],
    line: hex('#5FB3C4'), lineA: 0.3, amb: 0.5, road: hex('#101316'), edge: hex('#3E4652'), route: hex('#5FB3C4'), dash: hex('#CFCBC3'),
    ring: hex('#1C2026'), tyre: hex('#07090B'), glow: 0.3,
    members: ['#5FB3C4', '#6CC08B', '#E0B15A', '#D88AA6', '#79A8E8', '#A99BD6', '#6FBFAE', '#E9A55B'].map(hex)
  };
  function norm3(v) { var l = Math.hypot(v[0], v[1], v[2]); return [v[0] / l, v[1] / l, v[2] / l]; }
  DAY.sun = norm3(DAY.sun); NIGHT.sun = norm3(NIGHT.sun);
  function isDark() {
    var t = root.getAttribute('data-theme');
    if (t === 'dark') return true;
    if (t === 'light') return false;
    return win.matchMedia ? win.matchMedia('(prefers-color-scheme: dark)').matches : false;
  }
  var night = isDark() ? 1 : 0, nightTarget = night;
  function mixv(a, b, t) { return [a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t]; }
  function pal(key) { return mixv(DAY[key], NIGHT[key], night); }
  function paln(key) { return DAY[key] + (NIGHT[key] - DAY[key]) * night; }

  /* ---------- Matrices ---------- */
  function perspective(fovy, aspect, near, far, shift) {
    var f = 1 / Math.tan(fovy / 2), nf = 1 / (near - far);
    return [f / aspect, 0, 0, 0, 0, f, 0, 0, shift, 0, (far + near) * nf, -1, 0, 0, 2 * far * near * nf, 0];
  }
  function lookAt(e, c, up) {
    var z = norm3([e[0] - c[0], e[1] - c[1], e[2] - c[2]]);
    var x = norm3([up[1] * z[2] - up[2] * z[1], up[2] * z[0] - up[0] * z[2], up[0] * z[1] - up[1] * z[0]]);
    var y = [z[1] * x[2] - z[2] * x[1], z[2] * x[0] - z[0] * x[2], z[0] * x[1] - z[1] * x[0]];
    return [x[0], y[0], z[0], 0, x[1], y[1], z[1], 0, x[2], y[2], z[2], 0,
      -(x[0] * e[0] + x[1] * e[1] + x[2] * e[2]), -(y[0] * e[0] + y[1] * e[1] + y[2] * e[2]), -(z[0] * e[0] + z[1] * e[1] + z[2] * e[2]), 1];
  }
  function mul(a, b) {
    var o = new Array(16);
    for (var c = 0; c < 4; c++) for (var r2 = 0; r2 < 4; r2++) {
      o[c * 4 + r2] = a[r2] * b[c * 4] + a[4 + r2] * b[c * 4 + 1] + a[8 + r2] * b[c * 4 + 2] + a[12 + r2] * b[c * 4 + 3];
    }
    return o;
  }

  /* ---------- Size ---------- */
  var W = 0, H = 0, dpr = 1, cssW = 0;
  function resize() {
    var rect = host.getBoundingClientRect();
    cssW = rect.width;
    dpr = Math.min(win.devicePixelRatio || 1, DPR_CAP);
    var w = Math.max(1, Math.round(rect.width * dpr)), h = Math.max(1, Math.round(rect.height * dpr));
    if (w !== W || h !== H) { W = w; H = h; canvas.width = w; canvas.height = h; }
  }

  /* ---------- Frame ---------- */
  var tSim = 0, last = 0, raf = 0, running = false, drawn = false, seen = 0, slowSum = 0, slowN = 0;
  function draw(now) {
    raf = 0;
    if (!running) return;
    raf = win.requestAnimationFrame(draw);
    if (FRAME_MS && last && now - last < FRAME_MS - 1) return;
    var dt = last ? Math.min(0.1, (now - last) / 1000) : 0;
    last = now;
    // Display rate first. If the device cannot hold it (after the first frames, which compile shaders), 30 fps.
    if (!FRAME_MS && dt) {
      if (++seen > 20) { slowSum += dt * 1000; slowN++; }
      if (slowN >= 60) {
        if (slowSum / slowN > SLOW_FRAME_MS) { FRAME_MS = 1000 / 30; if (slowSum / slowN > 45) DPR_CAP = 1; }
        slowSum = 0; slowN = 0;
      }
    }
    tSim += dt;
    if (night !== nightTarget) {
      var step = dt / 0.6;
      night = night < nightTarget ? Math.min(nightTarget, night + step) : Math.max(nightTarget, night - step);
    }
    render(tSim);
    if (!drawn) { drawn = true; host.setAttribute('data-state', 'live'); }
  }

  function render(t) {
    resize();
    gl.viewport(0, 0, W, H);
    var aspect = W / H, wide = aspect > 1.15 && cssW >= 900; // wide: the desktop hero, words on the left
    var camZ = -t * SPEED;
    var lookZ = camZ - 62;
    var cx = roadX(camZ) * 0.55 + roadX(camZ - 20) * 0.45 + 5.5 * Math.sin(t * 0.05) + (wide ? -3 : 0);
    var cy = roadH(camZ) + (wide ? 15 : 17) + 2.0 * Math.sin(t * 0.07 + 1.0);
    cy = Math.max(cy, height(cx, camZ) + 4.5);
    var eye = [cx, cy, camZ];
    var target = [roadX(lookZ) + 1.5 * Math.sin(t * 0.04), roadH(lookZ) - 1.0, lookZ];
    // On wide screens the vanishing point sits right of centre, beside the headline.
    var proj = perspective((wide ? 46 : 58) * Math.PI / 180, aspect, 0.5, 520, wide ? -0.4 : 0);
    var vp = mul(proj, lookAt(eye, target, [0, 1, 0]));
    var fogR = [DEPTH * 0.18, DEPTH * 0.98];
    var fog = pal('fog');

    gl.disable(gl.DEPTH_TEST);
    gl.disable(gl.BLEND);
    gl.useProgram(sky.p);
    gl.bindBuffer(gl.ARRAY_BUFFER, skyBuf);
    gl.enableVertexAttribArray(sky.a.aP);
    gl.vertexAttribPointer(sky.a.aP, 2, gl.FLOAT, false, 0, 0);
    gl.uniform3fv(sky.u.uTop, pal('top'));
    gl.uniform3fv(sky.u.uHor, pal('hor'));
    gl.uniform1f(sky.u.uHorY, 0.45);
    gl.drawArrays(gl.TRIANGLES, 0, 3);
    gl.disableVertexAttribArray(sky.a.aP);

    gl.enable(gl.DEPTH_TEST);
    gl.depthMask(true);
    gl.clear(gl.DEPTH_BUFFER_BIT);

    gl.useProgram(terrain.p);
    gl.bindBuffer(gl.ARRAY_BUFFER, gridBuf);
    gl.enableVertexAttribArray(terrain.a.aG);
    gl.vertexAttribPointer(terrain.a.aG, 2, gl.FLOAT, false, 0, 0);
    gl.bindBuffer(gl.ELEMENT_ARRAY_BUFFER, idxBuf);
    gl.uniform2f(terrain.u.uO, Math.floor(cx / GRID) * GRID, Math.floor(camZ / GRID) * GRID + BEHIND);
    gl.uniformMatrix4fv(terrain.u.uVP, false, vp);
    gl.uniform3fv(terrain.u.uCam, eye);
    gl.uniform2fv(terrain.u.uFogR, fogR);
    gl.uniform3fv(terrain.u.uLow, pal('low'));
    gl.uniform3fv(terrain.u.uHigh, pal('high'));
    gl.uniform3fv(terrain.u.uFog, fog);
    gl.uniform3fv(terrain.u.uSun, norm3(pal('sun')));
    gl.uniform3fv(terrain.u.uLine, pal('line'));
    gl.uniform1f(terrain.u.uAmb, paln('amb'));
    gl.uniform1f(terrain.u.uLineA, paln('lineA'));
    gl.drawElements(gl.TRIANGLES, idxCount, gl.UNSIGNED_SHORT, 0);
    gl.disableVertexAttribArray(terrain.a.aG);

    gl.useProgram(road.p);
    gl.bindBuffer(gl.ARRAY_BUFFER, roadBuf);
    gl.enableVertexAttribArray(road.a.aR);
    gl.vertexAttribPointer(road.a.aR, 2, gl.FLOAT, false, 0, 0);
    gl.uniform1f(road.u.uZ0, Math.floor(camZ) + BEHIND);
    gl.uniformMatrix4fv(road.u.uVP, false, vp);
    gl.uniform3fv(road.u.uCam, eye);
    gl.uniform2fv(road.u.uFogR, fogR);
    gl.uniform1f(road.u.uW, ROAD_W);
    gl.uniform3fv(road.u.uRoad, pal('road'));
    gl.uniform3fv(road.u.uEdge, pal('edge'));
    gl.uniform3fv(road.u.uRoute, pal('route'));
    gl.uniform3fv(road.u.uDash, pal('dash'));
    gl.uniform3fv(road.u.uFog, fog);
    gl.uniform2f(road.u.uConvoy, camZ - CONVOY[CONVOY.length - 1].ahead + 3, camZ - CONVOY[0].ahead - 4);
    gl.enable(gl.POLYGON_OFFSET_FILL);
    gl.polygonOffset(-1, -2);
    gl.drawArrays(gl.TRIANGLE_STRIP, 0, roadN * 2);
    gl.disable(gl.POLYGON_OFFSET_FILL);
    gl.disableVertexAttribArray(road.a.aR);

    var mem = night > 0.5 ? NIGHT.members : DAY.members;
    for (var i = 0; i < CONVOY.length; i++) {
      var cv = CONVOY[i];
      var z = camZ - cv.ahead - 1.6 * Math.sin(t * 0.35 + cv.ph);
      var x = roadX(z) + cv.lane;
      var o = i * 8, col = mem[cv.c];
      riderArr[o] = x; riderArr[o + 1] = roadH(z) + (BIKE ? 0.84 : 0.95); riderArr[o + 2] = z;
      riderArr[o + 3] = col[0]; riderArr[o + 4] = col[1]; riderArr[o + 5] = col[2];
      // The lead sends a live "ping" every few seconds, like a position update.
      var ph = (t + i * 0.9) % (i === 0 ? 3.2 : 6.4);
      riderArr[o + 6] = ph < 1.6 ? Math.max(0.001, ph / 1.6) : 0;
      // Lean into the bend: the road's sideways curvature where the rider is.
      var curve = -(14.0 * 0.022 * 0.022 * Math.sin(z * 0.022) + 6.0 * 0.053 * 0.053 * Math.sin(z * 0.053 + 1.0));
      riderArr[o + 7] = Math.max(-0.3, Math.min(0.3, curve * LEAN));
    }
    gl.useProgram(riders.p);
    gl.bindBuffer(gl.ARRAY_BUFFER, riderBuf);
    gl.bufferData(gl.ARRAY_BUFFER, riderArr, gl.DYNAMIC_DRAW);
    gl.enableVertexAttribArray(riders.a.aP);
    gl.enableVertexAttribArray(riders.a.aC);
    gl.enableVertexAttribArray(riders.a.aFx);
    gl.vertexAttribPointer(riders.a.aP, 3, gl.FLOAT, false, 32, 0);
    gl.vertexAttribPointer(riders.a.aC, 3, gl.FLOAT, false, 32, 12);
    gl.vertexAttribPointer(riders.a.aFx, 2, gl.FLOAT, false, 32, 24);
    gl.uniformMatrix4fv(riders.u.uVP, false, vp);
    gl.uniform1f(riders.u.uScale, H * (BIKE ? 3.4 : (wide ? 3.0 : 2.6)));
    gl.uniform3fv(riders.u.uRing, pal('ring'));
    gl.uniform3fv(riders.u.uTyre, pal('tyre'));
    gl.uniform1f(riders.u.uGlow, paln('glow'));
    gl.uniform1f(riders.u.uBike, BIKE ? 1 : 0);
    gl.enable(gl.BLEND);
    gl.blendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA);
    gl.depthMask(false);
    gl.drawArrays(gl.POINTS, 0, CONVOY.length);
    gl.depthMask(true);
    gl.disableVertexAttribArray(riders.a.aP);
    gl.disableVertexAttribArray(riders.a.aC);
    gl.disableVertexAttribArray(riders.a.aFx);
  }

  /* ---------- Lifecycle: run only while it can be seen ---------- */
  var onScreen = true, reduce = false;
  var reduceMQ = win.matchMedia ? win.matchMedia('(prefers-reduced-motion: reduce)') : null;
  if (reduceMQ) reduce = reduceMQ.matches;
  function update() {
    var should = onScreen && !doc.hidden && !reduce && !lost;
    if (should && !running) { running = true; last = 0; if (!raf) raf = win.requestAnimationFrame(draw); }
    else if (!should && running) { running = false; if (raf) { win.cancelAnimationFrame(raf); raf = 0; } }
  }
  var lost = false;
  canvas.addEventListener('webglcontextlost', function (e) { e.preventDefault(); lost = true; update(); fail('context-lost'); }, false);
  if ('IntersectionObserver' in win) {
    new IntersectionObserver(function (en) { onScreen = en[0].isIntersecting; update(); }, { rootMargin: '80px' }).observe(host);
  }
  doc.addEventListener('visibilitychange', update);
  if (reduceMQ && reduceMQ.addEventListener) reduceMQ.addEventListener('change', function (e) { reduce = e.matches; update(); });
  if ('MutationObserver' in win) {
    new MutationObserver(function () { nightTarget = isDark() ? 1 : 0; if (!running && drawn) { night = nightTarget; render(tSim); } })
      .observe(root, { attributes: true, attributeFilter: ['data-theme'] });
  }
  // "System" theme (no data-theme): follow the phone or computer switching between light and dark.
  var schemeMQ = win.matchMedia ? win.matchMedia('(prefers-color-scheme: dark)') : null;
  if (schemeMQ && schemeMQ.addEventListener) schemeMQ.addEventListener('change', function () { nightTarget = isDark() ? 1 : 0; if (!running && drawn) { night = nightTarget; render(tSim); } });
  win.addEventListener('resize', function () { if (!running && drawn) render(tSim); }, { passive: true });

  host.appendChild(canvas);
  host.setAttribute('data-state', 'starting');
  update();
})();
