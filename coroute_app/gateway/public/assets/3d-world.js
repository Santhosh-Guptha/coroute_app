/* ==========================================================================
   CoRoute Fully 3D Interactive World Engine
   Pure Canvas 2D with High-Precision 3D Matrix Mathematics.
   60 FPS, Zero External Dependencies, Minimalist & Expert-Level Architecture.
   ========================================================================== */

(function () {
  'use strict';

  var doc = document;
  var win = window;

  function initWorld3D() {
    var canvas = doc.getElementById('world3d-canvas');
    if (!canvas) return;
    var ctx = canvas.getContext('2d');
    if (!ctx) return;

    if (!ctx.roundRect) {
      ctx.roundRect = function (x, y, w, h, r) {
        var rad = typeof r === 'number' ? r : 4;
        this.moveTo(x + rad, y);
        this.lineTo(x + w - rad, y);
        this.quadraticCurveTo(x + w, y, x + w, y + rad);
        this.lineTo(x + w, y + h - rad);
        this.quadraticCurveTo(x + w, y + h, x + w - rad, y + h);
        this.lineTo(x + rad, y + h);
        this.quadraticCurveTo(x, y + h, x, y + h - rad);
        this.lineTo(x, y + rad);
        this.quadraticCurveTo(x, y, x + rad, y);
        return this;
      };
    }

    var prefersReduced = win.matchMedia && win.matchMedia('(prefers-reduced-motion: reduce)').matches;

    // Palette & Tokens
    var THEME = {
      asphalt: '#0B0D0E',
      surface: '#121516',
      roadSurface: '#181C1E',
      roadEdge: '#32383B',
      routeLine: '#FF6F2E',
      routeGlow: 'rgba(255, 111, 46, 0.45)',
      dash: 'rgba(242, 238, 231, 0.35)',
      cyan: '#3EE0EC',
      cyanGlow: 'rgba(62, 224, 236, 0.35)',
      amber: '#FFB347',
      orange: '#FF6F2E',
      green: '#4FD18B',
      red: '#FF4D4A',
      meshLink: 'rgba(79, 209, 139, 0.35)',
      meshPacket: '#4FD18B',
      headlight: 'rgba(255, 245, 220, 0.12)',
      taillight: '#FF4D4A',
      star: 'rgba(242, 238, 231, 0.65)'
    };

    // Camera Modes
    var CAM_MODES = {
      CHASE: 'chase',       // Third-person chase cam behind player bike
      COCKPIT: 'cockpit',   // First-person handlebar helmet view
      ORBIT: 'orbit',       // Free 360-degree orbital camera
      RADAR: 'radar',       // High-altitude 5km tactical radar dome view
      SATELLITE: 'satellite'// High-orbit space perspective
    };

    // Engine State
    var state = {
      W: win.innerWidth || 1200,
      H: win.innerHeight || 800,
      dpr: Math.min(win.devicePixelRatio || 1, 2),
      camMode: CAM_MODES.CHASE,
      simTime: 0,
      simSpeed: 1.0,
      scrollProgress: 0,
      // Camera 3D Transform
      cam: { x: 0, y: 18, z: -45 },
      target: { x: 0, y: 8, z: 60 },
      fov: 650,
      // Free Orbit Controls
      orbitYaw: 0.3,
      orbitPitch: 0.38,
      orbitDist: 220,
      targetDist: 220,
      isDragging: false,
      lastMouseX: 0,
      lastMouseY: 0,
      vx: 0,
      vy: 0,
      // Gyroscope
      gyroYaw: 0,
      gyroPitch: 0,
      gyroActive: false,
      // Audio Synth
      audioEnabled: false,
      audioCtx: null,
      // Focused / Inspected 3D Node
      focusedNode: null,
      hoveredNode: null
    };

    // 5 Convoy Motorcycles along the road corridor
    var RIDERS = [
      { id: 'AK', callsign: 'AK', role: 'Lead', offsetS: 140, col: THEME.amber, speed: 63, lean: 0, wheelAngle: 0 },
      { id: 'YOU', callsign: 'You', role: 'Center', offsetS: 40, col: THEME.orange, speed: 61, lean: 0, wheelAngle: 0 },
      { id: 'RS', callsign: 'RS', role: 'Pack', offsetS: -65, col: THEME.cyan, speed: 60, lean: 0, wheelAngle: 0 },
      { id: 'PJ', callsign: 'PJ', role: 'Scout', offsetS: -180, col: THEME.green, speed: 62, lean: 0, wheelAngle: 0 },
      { id: 'MV', callsign: 'MV', role: 'Sweeper', offsetS: -310, col: THEME.amber, speed: 58, lean: 0, wheelAngle: 0 }
    ];

    // Starfield Points (3D Background Stars)
    var STARS = [];
    for (var s = 0; s < 180; s++) {
      STARS.push({
        x: (Math.random() - 0.5) * 2000,
        y: Math.random() * 800 + 100,
        z: (Math.random() - 0.5) * 2000,
        size: Math.random() * 1.5 + 0.5
      });
    }

    // 3D Mountain Pass Spline Function
    function roadSpline(s) {
      var x = 110 * Math.sin(s * 0.007) + 45 * Math.sin(s * 0.021) + 15 * Math.cos(s * 0.045);
      var y = 28 * Math.sin(s * 0.006) + 75 * (s / 1600) + 10 * Math.sin(s * 0.028); // Elevation climb
      var z = s;
      return { x: x, y: y, z: z };
    }

    // Spline Tangent
    function roadTangent(s) {
      var ds = 1.0;
      var p1 = roadSpline(s - ds);
      var p2 = roadSpline(s + ds);
      var dx = p2.x - p1.x;
      var dy = p2.y - p1.y;
      var dz = p2.z - p1.z;
      var len = Math.sqrt(dx * dx + dy * dy + dz * dz) || 1;
      return { x: dx / len, y: dy / len, z: dz / len, curvature: (p2.x - 2 * roadSpline(s).x + p1.x) };
    }

    // 3D Perspective Projection Matrix Engine
    function project(p, cam, target) {
      // Vector from camera to point
      var dx = p.x - cam.x;
      var dy = p.y - cam.y;
      var dz = p.z - cam.z;

      // Look direction
      var fx = target.x - cam.x;
      var fy = target.y - cam.y;
      var fz = target.z - cam.z;
      var fLen = Math.sqrt(fx * fx + fy * fy + fz * fz) || 1;
      fx /= fLen; fy /= fLen; fz /= fLen;

      // Right vector (Cross look with UP [0,1,0])
      var rx = fz;
      var ry = 0;
      var rz = -fx;
      var rLen = Math.sqrt(rx * rx + rz * rz) || 1;
      rx /= rLen; rz /= rLen;

      // True Up vector (Cross Right with Look)
      var ux = ry * fz - rz * fy;
      var uy = rz * fx - rx * fz;
      var uz = rx * fy - ry * fx;

      // Camera space coordinates
      var cx = dx * rx + dy * ry + dz * rz;
      var cy = dx * ux + dy * uy + dz * uz;
      var cz = dx * fx + dy * fy + dz * fz;

      if (cz < 4.0) cz = 4.0; // Near plane clip

      var scale = state.fov / cz;
      var screenX = state.W / 2 + cx * scale;
      var screenY = state.H / 2 - cy * scale;

      return {
        x: screenX,
        y: screenY,
        z: cz,
        scale: scale,
        visible: cz > 5.0 && screenX > -200 && screenX < state.W + 200 && screenY > -200 && screenY < state.H + 200
      };
    }

    // Window Resize Handler
    function handleResize() {
      state.W = win.innerWidth || 1200;
      state.H = win.innerHeight || 800;
      state.dpr = Math.min(win.devicePixelRatio || 1, 2);
      canvas.width = Math.round(state.W * state.dpr);
      canvas.height = Math.round(state.H * state.dpr);
      ctx.setTransform(state.dpr, 0, 0, state.dpr, 0, 0);
      state.fov = Math.min(state.W, state.H) * 1.15;
    }
    handleResize();
    win.addEventListener('resize', handleResize, { passive: true });

    // Procedural Web Audio Telemetry Synthesizer
    function playChime(freq, type, duration) {
      if (!state.audioEnabled) return;
      try {
        if (!state.audioCtx) {
          state.audioCtx = new (win.AudioContext || win.webkitAudioContext)();
        }
        var actx = state.audioCtx;
        if (actx.state === 'suspended') actx.resume();

        var osc = actx.createOscillator();
        var gain = actx.createGain();
        osc.type = type || 'sine';
        osc.frequency.setValueAtTime(freq || 880, actx.currentTime);
        gain.gain.setValueAtTime(0.08, actx.currentTime);
        gain.gain.exponentialRampToValueAtTime(0.0001, actx.currentTime + (duration || 0.25));

        osc.connect(gain);
        gain.connect(actx.destination);
        osc.start();
        osc.stop(actx.currentTime + (duration || 0.25));
      } catch (e) {}
    }

    // Pointer Drag & Orbit Controls
    function onPointerDown(e) {
      if (e.target !== canvas) return;
      state.isDragging = true;
      state.lastMouseX = e.clientX;
      state.lastMouseY = e.clientY;
      state.vx = 0;
      state.vy = 0;
    }

    function onPointerMove(e) {
      if (!state.isDragging) {
        // Test hovering near clickable 3D nodes
        checkHover(e.clientX, e.clientY);
        return;
      }
      var dx = e.clientX - state.lastMouseX;
      var dy = e.clientY - state.lastMouseY;
      state.vx = dx * 0.006;
      state.vy = dy * 0.006;
      state.orbitYaw += state.vx;
      state.orbitPitch = Math.max(-0.4, Math.min(1.4, state.orbitPitch + state.vy));
      state.lastMouseX = e.clientX;
      state.lastMouseY = e.clientY;
    }

    function onPointerUp(e) {
      if (state.isDragging && Math.abs(state.vx) < 0.002 && Math.abs(state.vy) < 0.002) {
        checkClick(e.clientX, e.clientY);
      }
      state.isDragging = false;
    }

    canvas.addEventListener('pointerdown', onPointerDown);
    win.addEventListener('pointermove', onPointerMove, { passive: true });
    win.addEventListener('pointerup', onPointerUp, { passive: true });

    // Wheel Zoom
    canvas.addEventListener('wheel', function (e) {
      e.preventDefault();
      state.targetDist = Math.max(80, Math.min(650, state.targetDist + e.deltaY * 0.4));
    }, { passive: false });

    // Gyroscope tilt
    if (win.DeviceOrientationEvent) {
      win.addEventListener('deviceorientation', function (e) {
        if (e.gamma !== null && e.beta !== null) {
          state.gyroActive = true;
          state.gyroYaw = (e.gamma || 0) * 0.006;
          state.gyroPitch = ((e.beta || 45) - 45) * 0.005;
        }
      }, { passive: true });
    }

    // Scroll-Linked Waypoints Tracking
    function updateScrollProgress() {
      var scrollY = win.scrollY || doc.documentElement.scrollTop || 0;
      var maxScroll = (doc.documentElement.scrollHeight - win.innerHeight) || 1;
      state.scrollProgress = Math.max(0, Math.min(1, scrollY / maxScroll));

      // Update active spatial navigation rail item
      var navItems = doc.querySelectorAll('.spatial-nav-item');
      if (navItems.length) {
        var activeIdx = Math.min(navItems.length - 1, Math.floor(state.scrollProgress * navItems.length + 0.1));
        navItems.forEach(function (btn, i) {
          btn.classList.toggle('is-active', i === activeIdx);
        });
      }
    }
    win.addEventListener('scroll', updateScrollProgress, { passive: true });

    // Camera Mode Switching
    function setCameraMode(mode) {
      state.camMode = mode;
      playChime(mode === CAM_MODES.COCKPIT ? 1200 : mode === CAM_MODES.SATELLITE ? 440 : 880, 'sine', 0.2);

      var btns = doc.querySelectorAll('.cam-btn');
      btns.forEach(function (b) {
        var isActive = b.getAttribute('data-cam') === mode;
        b.classList.toggle('is-active', isActive);
        b.setAttribute('aria-pressed', isActive ? 'true' : 'false');
      });
    }

    var camBtns = doc.querySelectorAll('.cam-btn');
    camBtns.forEach(function (btn) {
      btn.addEventListener('click', function () {
        setCameraMode(btn.getAttribute('data-cam'));
      });
    });

    // Speed / Simulation Toggle
    var speedBtn = doc.getElementById('sim-speed-btn');
    var speedVal = doc.getElementById('speed-readout');
    if (speedBtn) {
      speedBtn.addEventListener('click', function () {
        if (state.simSpeed === 1.0) {
          state.simSpeed = 2.0;
          if (speedVal) speedVal.textContent = '120 KM/H';
          speedBtn.classList.add('is-active');
          playChime(1320, 'triangle', 0.15);
        } else if (state.simSpeed === 2.0) {
          state.simSpeed = 0;
          if (speedVal) speedVal.textContent = '0 KM/H';
          speedBtn.classList.remove('is-active');
          playChime(350, 'sine', 0.2);
        } else {
          state.simSpeed = 1.0;
          if (speedVal) speedVal.textContent = '61 KM/H';
          speedBtn.classList.remove('is-active');
          playChime(660, 'sine', 0.15);
        }
      });
    }

    // Audio Toggle
    var audioBtn = doc.getElementById('audio-toggle-btn');
    if (audioBtn) {
      audioBtn.addEventListener('click', function () {
        state.audioEnabled = !state.audioEnabled;
        audioBtn.classList.toggle('is-active', state.audioEnabled);
        audioBtn.setAttribute('aria-pressed', state.audioEnabled ? 'true' : 'false');
        if (state.audioEnabled) playChime(960, 'sine', 0.3);
      });
    }

    // Spatial Fly-To Navigation Buttons
    var flyBtns = doc.querySelectorAll('[data-fly-s]');
    flyBtns.forEach(function (btn) {
      btn.addEventListener('click', function () {
        var sTarget = parseFloat(btn.getAttribute('data-fly-s')) || 0;
        var camTarget = btn.getAttribute('data-fly-cam') || CAM_MODES.CHASE;
        setCameraMode(camTarget);

        // Smooth scroll to matching section
        var targetId = btn.getAttribute('data-fly-target');
        var el = targetId && doc.getElementById(targetId);
        if (el) {
          el.scrollIntoView({ behavior: 'smooth', block: 'center' });
        }
      });
    });

    // Inspect Card Interaction
    var inspectCard = doc.getElementById('world3d-inspect');
    var inspectClose = doc.getElementById('inspect-close');
    if (inspectClose) {
      inspectClose.addEventListener('click', function () {
        if (inspectCard) inspectCard.classList.remove('is-visible');
        state.focusedNode = null;
      });
    }

    // 3D Object Picking Cache
    var clickableObjects = [];
    function checkHover(mx, my) {
      var found = null;
      for (var i = 0; i < clickableObjects.length; i++) {
        var obj = clickableObjects[i];
        if (!obj.screen.visible) continue;
        var dx = mx - obj.screen.x;
        var dy = my - obj.screen.y;
        if (dx * dx + dy * dy < 32 * 32) {
          found = obj;
          break;
        }
      }
      state.hoveredNode = found;
      canvas.style.cursor = found ? 'pointer' : (state.isDragging ? 'grabbing' : 'grab');
    }

    function checkClick(mx, my) {
      checkHover(mx, my);
      if (state.hoveredNode) {
        showInspectCard(state.hoveredNode, mx, my);
      } else if (inspectCard) {
        inspectCard.classList.remove('is-visible');
      }
    }

    function showInspectCard(obj, mx, my) {
      if (!inspectCard) return;
      playChime(1100, 'sine', 0.2);

      var titleEl = doc.getElementById('inspect-title');
      var descEl = doc.getElementById('inspect-desc');
      var stat1El = doc.getElementById('inspect-stat1');
      var stat2El = doc.getElementById('inspect-stat2');

      if (titleEl) titleEl.textContent = obj.title;
      if (descEl) descEl.textContent = obj.desc;
      if (stat1El) stat1El.textContent = obj.stat1;
      if (stat2El) stat2El.textContent = obj.stat2;

      inspectCard.style.left = Math.min(state.W - 340, Math.max(16, mx + 16)) + 'px';
      inspectCard.style.top = Math.min(state.H - 180, Math.max(80, my - 60)) + 'px';
      inspectCard.classList.add('is-visible');
    }

    // =========================================================================
    // 3D Render Routines
    // =========================================================================

    // 1. Draw Starfield
    function renderStars(cam, target) {
      ctx.save();
      for (var i = 0; i < STARS.length; i++) {
        var s = STARS[i];
        var pt = project({ x: s.x + cam.x * 0.9, y: s.y, z: s.z + cam.z * 0.9 }, cam, target);
        if (pt.visible) {
          ctx.beginPath();
          ctx.arc(pt.x, pt.y, s.size, 0, Math.PI * 2);
          ctx.fillStyle = THEME.star;
          ctx.fill();
        }
      }
      ctx.restore();
    }

    // 2. Draw Topographical Mountain Ridge Elevation Contours
    function renderMountains(cam, target, baseS) {
      ctx.save();
      var numRidges = 36;
      var step = 45;
      var halfWidth = 320;
      var samples = 16;

      for (var r = -12; r <= numRidges; r++) {
        var s = baseS + r * step;
        var center = roadSpline(s);

        var pts = [];
        for (var j = -samples / 2; j <= samples / 2; j++) {
          var u = (j / (samples / 2)) * halfWidth;
          var ad = Math.abs(u);
          // Elevation profile: mountain peaks rise higher on flanks
          var peakElev = Math.max(0, ad - 35) * 0.55;
          var noise = 16 * Math.sin(u * 0.03 + s * 0.015) + 10 * Math.cos(s * 0.04);
          var elev = center.y - 15 + peakElev + noise;
          var pt = project({ x: center.x + u, y: elev, z: s }, cam, target);
          pts.push(pt);
        }

        // Draw Contour Curve
        ctx.beginPath();
        var started = false;
        for (var k = 0; k < pts.length; k++) {
          if (pts[k].visible) {
            if (!started) { ctx.moveTo(pts[k].x, pts[k].y); started = true; }
            else { ctx.lineTo(pts[k].x, pts[k].y); }
          }
        }
        var alpha = Math.max(0.03, 0.25 - Math.abs(r) / (numRidges * 1.5));
        ctx.strokeStyle = 'rgba(62, 224, 236, ' + alpha.toFixed(3) + ')';
        ctx.lineWidth = 1.0;
        ctx.stroke();
      }
      ctx.restore();
    }

    // 3. Draw 3D Winding Road Ribbon & Route Line
    function renderRoad(cam, target, baseS) {
      ctx.save();
      var steps = 180;
      var sSpan = 1600;
      var roadHalfW = 9.5;

      var Ls = [], Rs = [], Cs = [], Route = [];

      for (var i = 0; i <= steps; i++) {
        var s = baseS - 400 + (i / steps) * sSpan;
        var pt = roadSpline(s);
        var t = roadTangent(s);

        // Normal perpendicular to tangent in XZ plane
        var nx = -t.z;
        var nz = t.x;

        var l = project({ x: pt.x + nx * roadHalfW, y: pt.y, z: pt.z + nz * roadHalfW }, cam, target);
        var r = project({ x: pt.x - nx * roadHalfW, y: pt.y, z: pt.z - nz * roadHalfW }, cam, target);
        var c = project({ x: pt.x, y: pt.y + 0.3, z: pt.z }, cam, target);
        var rt = project({ x: pt.x - nx * 3.5, y: pt.y + 0.4, z: pt.z - nz * 3.5 }, cam, target);

        Ls.push(l);
        Rs.push(r);
        Cs.push(c);
        Route.push(rt);
      }

      // Asphalt Surface Polygon
      ctx.beginPath();
      var started = false;
      for (var i = 0; i < Ls.length; i++) {
        if (Ls[i].visible) {
          if (!started) { ctx.moveTo(Ls[i].x, Ls[i].y); started = true; }
          else { ctx.lineTo(Ls[i].x, Ls[i].y); }
        }
      }
      for (var i = Rs.length - 1; i >= 0; i--) {
        if (Rs[i].visible) ctx.lineTo(Rs[i].x, Rs[i].y);
      }
      ctx.closePath();
      ctx.fillStyle = THEME.roadSurface;
      ctx.fill();

      // Road Edge Strokes
      function strokeLine(arr, col, w) {
        ctx.beginPath();
        var st = false;
        for (var i = 0; i < arr.length; i++) {
          if (arr[i].visible) {
            if (!st) { ctx.moveTo(arr[i].x, arr[i].y); st = true; }
            else { ctx.lineTo(arr[i].x, arr[i].y); }
          }
        }
        ctx.strokeStyle = col;
        ctx.lineWidth = w;
        ctx.stroke();
      }

      strokeLine(Ls, THEME.roadEdge, 1.5);
      strokeLine(Rs, THEME.roadEdge, 1.5);

      // Glowing Route Line (Orange)
      ctx.shadowColor = THEME.routeGlow;
      ctx.shadowBlur = 14;
      strokeLine(Route, THEME.routeLine, 3.6);
      ctx.shadowBlur = 0;

      // Dashed White Center Line
      ctx.setLineDash([10, 16]);
      strokeLine(Cs, THEME.dash, 1.2);
      ctx.setLineDash([]);

      ctx.restore();
    }

    // 4. Draw 3D Mountain Tunnel Portal (Dead Reckoning & IMU Section)
    function renderTunnel(cam, target) {
      ctx.save();
      var tunnelStartS = 700;
      var tunnelEndS = 980;
      var numRings = 18;

      for (var i = 0; i <= numRings; i++) {
        var s = tunnelStartS + (i / numRings) * (tunnelEndS - tunnelStartS);
        var pt = roadSpline(s);
        var t = roadTangent(s);
        var nx = -t.z;
        var nz = t.x;

        // Tunnel Portal Arch
        var archPts = [];
        var numSegs = 14;
        var archRadius = 16;
        for (var j = 0; j <= numSegs; j++) {
          var angle = (j / numSegs) * Math.PI; // 0 to PI arch
          var rx = -Math.cos(angle) * archRadius;
          var ry = Math.sin(angle) * archRadius;
          var world = {
            x: pt.x + nx * rx,
            y: pt.y + ry,
            z: pt.z + nz * rx
          };
          archPts.push(project(world, cam, target));
        }

        ctx.beginPath();
        var st = false;
        archPts.forEach(function (p) {
          if (p.visible) {
            if (!st) { ctx.moveTo(p.x, p.y); st = true; }
            else { ctx.lineTo(p.x, p.y); }
          }
        });

        // Entrance portal gets glowing cyan neon, internal rings get subtle cyan
        var isEntrance = i === 0 || i === numRings;
        ctx.strokeStyle = isEntrance ? THEME.cyan : 'rgba(62, 224, 236, 0.28)';
        ctx.lineWidth = isEntrance ? 3.0 : 1.2;
        ctx.stroke();

        if (isEntrance && i === 0) {
          var portalTop = archPts[Math.floor(numSegs / 2)];
          if (portalTop && portalTop.visible) {
            ctx.fillStyle = THEME.cyan;
            ctx.font = 'bold 11px monospace';
            ctx.textAlign = 'center';
            ctx.fillText('TUNNEL IMU: 10 KM BLACKOUT', portalTop.x, portalTop.y - 12);

            clickableObjects.push({
              title: 'Dead Reckoning & Tunnel IMU',
              desc: 'Continuous along-route motion tracking through 10 km GPS-blackout tunnels using 6-axis accelerometer & gyro fusion.',
              stat1: 'SENSOR: 6-Axis IMU Fusion',
              stat2: 'RANGE: 10 km Zero-GPS',
              screen: portalTop
            });
          }
        }
      }
      ctx.restore();
    }

    // 5. Draw 3D Low-Altitude Orbital Satellite
    function renderSatellite(cam, target, t) {
      ctx.save();
      var satWorld = {
        x: 180 + 30 * Math.sin(t * 0.4),
        y: 380 + 15 * Math.cos(t * 0.3),
        z: 320 + 20 * Math.cos(t * 0.4)
      };

      var satPt = project(satWorld, cam, target);
      if (satPt.visible) {
        // Laser Telemetry Beam targeting the road corridor pass
        var groundTarget = roadSpline(180);
        var groundPt = project(groundTarget, cam, target);

        if (groundPt.visible) {
          ctx.beginPath();
          ctx.moveTo(satPt.x, satPt.y);
          ctx.lineTo(groundPt.x, groundPt.y);
          ctx.strokeStyle = 'rgba(255, 179, 71, 0.25)';
          ctx.lineWidth = 1.5;
          ctx.setLineDash([4, 6]);
          ctx.stroke();
          ctx.setLineDash([]);
        }

        // Satellite Body
        ctx.beginPath();
        ctx.arc(satPt.x, satPt.y, 7 * satPt.scale, 0, Math.PI * 2);
        ctx.fillStyle = THEME.amber;
        ctx.shadowColor = THEME.amber;
        ctx.shadowBlur = 16;
        ctx.fill();
        ctx.shadowBlur = 0;

        // Solar Wings
        var wingSpan = 22 * satPt.scale;
        ctx.beginPath();
        ctx.moveTo(satPt.x - wingSpan, satPt.y - 3);
        ctx.lineTo(satPt.x + wingSpan, satPt.y - 3);
        ctx.lineTo(satPt.x + wingSpan, satPt.y + 3);
        ctx.lineTo(satPt.x - wingSpan, satPt.y + 3);
        ctx.closePath();
        ctx.fillStyle = THEME.cyan;
        ctx.fill();

        // Label
        ctx.fillStyle = THEME.amber;
        ctx.font = 'bold 10px monospace';
        ctx.textAlign = 'center';
        ctx.fillText('SATELLITE SOS GATEWAY', satPt.x, satPt.y - 14);

        clickableObjects.push({
          title: 'Satellite SOS Gateway Relay',
          desc: 'Direct low-altitude satellite link when cellular coverage drops to zero in high mountain passes (Ladakh & Spiti).',
          stat1: 'COVERAGE: 100% Global Pass',
          stat2: 'LATENCY: Emergency Priority',
          screen: satPt
        });
      }
      ctx.restore();
    }

    // 6. Draw 3D Tactical Radar Sphere Grid
    function renderRadarSphere(cam, target, t, centerPos) {
      if (state.camMode !== CAM_MODES.RADAR) return;
      ctx.save();
      var radii = [90, 200, 340];
      var labels = ['1.0 KM', '2.5 KM', '5.0 KM'];

      radii.forEach(function (r, idx) {
        var pts = [];
        var segs = 64;
        for (var i = 0; i <= segs; i++) {
          var th = (i / segs) * Math.PI * 2;
          var pt = project({
            x: centerPos.x + r * Math.cos(th),
            y: centerPos.y,
            z: centerPos.z + r * Math.sin(th)
          }, cam, target);
          pts.push(pt);
        }

        ctx.beginPath();
        var st = false;
        pts.forEach(function (p) {
          if (p.visible) {
            if (!st) { ctx.moveTo(p.x, p.y); st = true; }
            else { ctx.lineTo(p.x, p.y); }
          }
        });
        ctx.strokeStyle = 'rgba(62, 224, 236, 0.3)';
        ctx.lineWidth = 1.0;
        ctx.stroke();

        var lblPt = project({
          x: centerPos.x + r * 0.95,
          y: centerPos.y,
          z: centerPos.z
        }, cam, target);
        if (lblPt.visible) {
          ctx.fillStyle = THEME.cyan;
          ctx.font = '9px monospace';
          ctx.fillText(labels[idx], lblPt.x + 4, lblPt.y - 2);
        }
      });

      // Rotating Radar Sweep Beam
      var sweep = (t * 1.8) % (Math.PI * 2);
      var origin = project(centerPos, cam, target);
      var edgePt = project({
        x: centerPos.x + 340 * Math.cos(sweep),
        y: centerPos.y,
        z: centerPos.z + 340 * Math.sin(sweep)
      }, cam, target);

      if (origin.visible && edgePt.visible) {
        ctx.beginPath();
        ctx.moveTo(origin.x, origin.y);
        ctx.lineTo(edgePt.x, edgePt.y);
        ctx.strokeStyle = THEME.cyan;
        ctx.lineWidth = 2.0;
        ctx.shadowColor = THEME.cyan;
        ctx.shadowBlur = 10;
        ctx.stroke();
        ctx.shadowBlur = 0;
      }

      ctx.restore();
    }

    // 7. Draw Collective Road Hazard Marker
    function renderHazard(cam, target, t) {
      var hS = 320;
      var pos = roadSpline(hS);
      var pt = project({ x: pos.x, y: pos.y + 2.5, z: pos.z }, cam, target);
      if (!pt.visible) return;

      ctx.save();
      // Pulsing Danger Waves
      var pulse = (t * 2.2) % 1.0;
      var pr = (12 + pulse * 28) * pt.scale;
      ctx.beginPath();
      ctx.arc(pt.x, pt.y, pr, 0, Math.PI * 2);
      ctx.strokeStyle = 'rgba(255, 179, 71, ' + (1 - pulse) + ')';
      ctx.lineWidth = 1.5;
      ctx.stroke();

      // Warning Diamond
      var dSize = 10 * pt.scale;
      ctx.beginPath();
      ctx.moveTo(pt.x, pt.y - dSize);
      ctx.lineTo(pt.x + dSize, pt.y);
      ctx.lineTo(pt.x, pt.y + dSize);
      ctx.lineTo(pt.x - dSize, pt.y);
      ctx.closePath();
      ctx.fillStyle = THEME.amber;
      ctx.fill();

      ctx.fillStyle = '#0B0D0E';
      ctx.font = 'bold ' + Math.round(11 * pt.scale) + 'px sans-serif';
      ctx.textAlign = 'center';
      ctx.fillText('!', pt.x, pt.y + 4 * pt.scale);

      ctx.fillStyle = THEME.amber;
      ctx.font = 'bold 10px monospace';
      ctx.fillText('ROAD HAZARD: 300M', pt.x, pt.y - 16);

      clickableObjects.push({
        title: 'Collective Road Hazard AI Mesh',
        desc: 'Automatic detection of severe potholes, wet mud & oil slicks, broadcasting 300m spatial voice warnings to following riders.',
        stat1: 'DETECTION: IMU Bump Telemetry',
        stat2: 'CUE: 300m Spatial Audio',
        screen: pt
      });

      ctx.restore();
    }

    // 8. Draw 3D Motorcycles & Convoy Avatars
    function renderMotorcycle(rider, worldPos, tangent, cam, target, t, isPlayer) {
      var pt = project(worldPos, cam, target);
      if (!pt.visible) return;

      ctx.save();

      // Calculate Lean angle from curve tangent curvature
      var curveLean = Math.max(-0.4, Math.min(0.4, tangent.curvature * 0.15));
      rider.lean = rider.lean * 0.85 + curveLean * 0.15;

      var sc = pt.scale;
      var bikeL = 12 * sc;
      var bikeH = 10 * sc;

      // Volumetric Headlight Cone illuminating the asphalt ahead
      var lightAhead = {
        x: worldPos.x + tangent.x * 45,
        y: worldPos.y - 2,
        z: worldPos.z + tangent.z * 45
      };
      var lightPt = project(lightAhead, cam, target);
      if (lightPt.visible) {
        ctx.beginPath();
        ctx.moveTo(pt.x, pt.y - bikeH * 0.4);
        ctx.lineTo(lightPt.x - 24 * sc, lightPt.y);
        ctx.lineTo(lightPt.x + 24 * sc, lightPt.y);
        ctx.closePath();
        ctx.fillStyle = THEME.headlight;
        ctx.fill();
      }

      // Ground Altitude Drop Line & Shadow
      var groundPt = project({ x: worldPos.x, y: worldPos.y - 2.5, z: worldPos.z }, cam, target);
      if (groundPt.visible) {
        ctx.beginPath();
        ctx.moveTo(pt.x, pt.y);
        ctx.lineTo(groundPt.x, groundPt.y);
        ctx.strokeStyle = 'rgba(255, 255, 255, 0.15)';
        ctx.lineWidth = 1;
        ctx.stroke();

        ctx.beginPath();
        ctx.arc(groundPt.x, groundPt.y, bikeL * 0.6, 0, Math.PI * 2);
        ctx.fillStyle = 'rgba(0, 0, 0, 0.55)';
        ctx.fill();
      }

      // 3D Motorcycle Chassis & Fairing (Leaned with physics)
      ctx.translate(pt.x, pt.y);
      ctx.rotate(rider.lean);

      // Front & Rear Wheels
      ctx.beginPath();
      ctx.arc(-bikeL * 0.5, 0, 4.5 * sc, 0, Math.PI * 2);
      ctx.arc(bikeL * 0.5, 0, 4.5 * sc, 0, Math.PI * 2);
      ctx.fillStyle = '#111';
      ctx.fill();
      ctx.strokeStyle = '#444';
      ctx.lineWidth = 1.2;
      ctx.stroke();

      // Body Frame & Tank
      ctx.beginPath();
      ctx.moveTo(-bikeL * 0.5, -2 * sc);
      ctx.lineTo(-bikeL * 0.1, -bikeH * 0.6);
      ctx.lineTo(bikeL * 0.35, -bikeH * 0.5);
      ctx.lineTo(bikeL * 0.55, -2 * sc);
      ctx.closePath();
      ctx.fillStyle = rider.col;
      ctx.fill();

      // Rider Helmet
      ctx.beginPath();
      ctx.arc(0, -bikeH * 0.9, 3.8 * sc, 0, Math.PI * 2);
      ctx.fillStyle = '#FFFFFF';
      ctx.fill();

      // Red LED Taillight Glow
      ctx.beginPath();
      ctx.arc(-bikeL * 0.55, -2 * sc, 2.5 * sc, 0, Math.PI * 2);
      ctx.fillStyle = THEME.taillight;
      ctx.shadowColor = THEME.taillight;
      ctx.shadowBlur = 8;
      ctx.fill();
      ctx.shadowBlur = 0;

      // Smart Airbag Vest Forcefield Shield Pulse
      if (isPlayer || state.camMode === CAM_MODES.COCKPIT) {
        var shieldPulse = (t * 1.5) % 1.0;
        ctx.beginPath();
        ctx.arc(0, -bikeH * 0.5, (16 + shieldPulse * 12) * sc, 0, Math.PI * 2);
        ctx.strokeStyle = 'rgba(255, 77, 74, ' + (0.8 * (1 - shieldPulse)) + ')';
        ctx.lineWidth = 1.5;
        ctx.stroke();
      }

      ctx.rotate(-rider.lean);
      ctx.translate(-pt.x, -pt.y);

      // 3D Callsign Badge
      ctx.fillStyle = 'rgba(18, 21, 22, 0.88)';
      ctx.strokeStyle = rider.col;
      ctx.lineWidth = 1;
      var tagText = rider.callsign + ' (' + rider.role + ')';
      ctx.font = 'bold 11px sans-serif';
      var tw = ctx.measureText(tagText).width;
      var tagY = pt.y - bikeH - 14;

      ctx.beginPath();
      ctx.roundRect(pt.x - tw / 2 - 6, tagY - 14, tw + 12, 18, 4);
      ctx.fill();
      ctx.stroke();

      ctx.fillStyle = '#FFFFFF';
      ctx.textAlign = 'center';
      ctx.fillText(tagText, pt.x, tagY);

      clickableObjects.push({
        title: rider.callsign + ' (' + rider.role + ')',
        desc: 'Active Convoy Node. Synced via 0-hop Bluetooth P2P mesh with continuous IMU telemetry and airbag monitoring.',
        stat1: 'SPEED: ' + rider.speed + ' km/h',
        stat2: 'AIRBAG: BLE Armed (20ms)',
        screen: pt
      });

      ctx.restore();
    }

    // 9. Draw Living P2P Bluetooth Mesh Web
    function renderMeshWeb(riderCoords, cam, target, t) {
      ctx.save();
      var links = [[0, 1], [1, 2], [2, 3], [3, 4], [1, 3]];

      links.forEach(function (link, idx) {
        var r1 = riderCoords[link[0]];
        var r2 = riderCoords[link[1]];
        if (!r1 || !r2) return;

        var p1 = project(r1, cam, target);
        var p2 = project(r2, cam, target);
        if (!p1.visible || !p2.visible) return;

        // Mesh Luminous Connection Line
        ctx.beginPath();
        ctx.moveTo(p1.x, p1.y);
        ctx.lineTo(p2.x, p2.y);
        ctx.strokeStyle = THEME.meshLink;
        ctx.lineWidth = 1.2;
        ctx.stroke();

        // Flying Telemetry Packet Spark
        var pktT = (t * 2.2 + idx * 0.24) % 1.0;
        var px = p1.x + (p2.x - p1.x) * pktT;
        var py = p1.y + (p2.y - p1.y) * pktT;

        ctx.beginPath();
        ctx.arc(px, py, 3.2, 0, Math.PI * 2);
        ctx.fillStyle = THEME.meshPacket;
        ctx.shadowColor = THEME.meshPacket;
        ctx.shadowBlur = 8;
        ctx.fill();
        ctx.shadowBlur = 0;
      });
      ctx.restore();
    }

    // 10. Draw 1st Person Cockpit Handlebar & HUD Overlay
    function renderCockpitHUD() {
      if (state.camMode !== CAM_MODES.COCKPIT) return;
      ctx.save();

      // Lower Handlebar Frame
      var hY = state.H;
      ctx.fillStyle = 'rgba(15, 18, 19, 0.96)';
      ctx.strokeStyle = '#282E30';
      ctx.lineWidth = 2;

      ctx.beginPath();
      ctx.moveTo(0, hY);
      ctx.lineTo(state.W * 0.28, hY - 70);
      ctx.lineTo(state.W * 0.72, hY - 70);
      ctx.lineTo(state.W, hY);
      ctx.closePath();
      ctx.fill();
      ctx.stroke();

      // Handlebar Left & Right Grips
      ctx.fillStyle = '#222';
      ctx.fillRect(state.W * 0.05, hY - 85, state.W * 0.18, 24);
      ctx.fillRect(state.W * 0.77, hY - 85, state.W * 0.18, 24);

      // Handlebar BLE Remote Switch on Left Grip
      ctx.fillStyle = THEME.cyan;
      ctx.fillRect(state.W * 0.18, hY - 82, 18, 18);
      ctx.fillStyle = '#0B0D0E';
      ctx.font = 'bold 9px monospace';
      ctx.textAlign = 'center';
      ctx.fillText('PTT', state.W * 0.18 + 9, hY - 70);

      // Central Digital OLED Speedometer & Telemetry Display
      var oledW = 200;
      var oledH = 50;
      var oledX = state.W / 2 - oledW / 2;
      var oledY = hY - 65;

      ctx.fillStyle = '#000000';
      ctx.strokeStyle = THEME.cyan;
      ctx.lineWidth = 1.5;
      ctx.beginPath();
      ctx.roundRect(oledX, oledY, oledW, oledH, 6);
      ctx.fill();
      ctx.stroke();

      ctx.fillStyle = THEME.cyan;
      ctx.font = 'bold 22px monospace';
      ctx.textAlign = 'center';
      ctx.fillText((state.simSpeed > 0 ? (61 * state.simSpeed).toFixed(0) : '0') + ' KM/H', state.W / 2, oledY + 28);

      ctx.font = '9px monospace';
      ctx.fillStyle = THEME.amber;
      ctx.fillText('AIRBAG: ARMED | TUNNEL IMU: OK', state.W / 2, oledY + 44);

      ctx.restore();
    }

    // =========================================================================
    // Main 60 FPS Render Loop
    // =========================================================================
    var lastNow = performance.now();

    function frame(now) {
      var dt = Math.min(0.08, (now - lastNow) / 1000);
      lastNow = now;

      state.simTime += dt * state.simSpeed;
      clickableObjects = [];

      // Compute Global Convoy Progression along spline
      // Scroll moves the baseline forward; simulation adds speed
      var scrollDist = state.scrollProgress * 1500;
      var baseS = scrollDist + (state.simTime * 25);

      // Calculate Player ('You') Position
      var playerWorld = roadSpline(baseS + RIDERS[1].offsetS);
      var playerTangent = roadTangent(baseS + RIDERS[1].offsetS);

      // Camera Positioning by Mode
      var targetCam = { x: 0, y: 0, z: 0 };
      var targetLook = { x: 0, y: 0, z: 0 };

      if (state.camMode === CAM_MODES.CHASE) {
        // Third-person chase cam behind player bike
        targetCam.x = playerWorld.x - playerTangent.x * 48;
        targetCam.y = playerWorld.y + 16;
        targetCam.z = playerWorld.z - playerTangent.z * 48;

        targetLook.x = playerWorld.x + playerTangent.x * 40;
        targetLook.y = playerWorld.y + 5;
        targetLook.z = playerWorld.z + playerTangent.z * 40;

      } else if (state.camMode === CAM_MODES.COCKPIT) {
        // First-person handlebar helmet view
        targetCam.x = playerWorld.x + playerTangent.x * 2;
        targetCam.y = playerWorld.y + 7.5;
        targetCam.z = playerWorld.z + playerTangent.z * 2;

        targetLook.x = playerWorld.x + playerTangent.x * 120;
        targetLook.y = playerWorld.y + 6;
        targetLook.z = playerWorld.z + playerTangent.z * 120;

      } else if (state.camMode === CAM_MODES.ORBIT) {
        // Free 360-degree Orbit around convoy center
        if (!state.isDragging) {
          state.orbitYaw += state.vx;
          state.orbitPitch = Math.max(-0.4, Math.min(1.4, state.orbitPitch + state.vy));
          state.vx *= 0.92;
          state.vy *= 0.92;
          if (!prefersReduced) state.orbitYaw += dt * 0.12;
        }

        state.orbitDist += (state.targetDist - state.orbitDist) * 0.12;

        var cy = Math.cos(state.orbitYaw + (state.gyroActive ? state.gyroYaw : 0));
        var sy = Math.sin(state.orbitYaw + (state.gyroActive ? state.gyroYaw : 0));
        var cp = Math.cos(state.orbitPitch + (state.gyroActive ? state.gyroPitch : 0));
        var sp = Math.sin(state.orbitPitch + (state.gyroActive ? state.gyroPitch : 0));

        targetLook = { x: playerWorld.x, y: playerWorld.y + 8, z: playerWorld.z };
        targetCam = {
          x: playerWorld.x + state.orbitDist * sy * cp,
          y: playerWorld.y + state.orbitDist * sp + 25,
          z: playerWorld.z - state.orbitDist * cy * cp
        };

      } else if (state.camMode === CAM_MODES.RADAR) {
        // High-altitude 5km tactical radar dome
        targetLook = { x: playerWorld.x, y: playerWorld.y, z: playerWorld.z };
        targetCam = { x: playerWorld.x, y: playerWorld.y + 420, z: playerWorld.z - 120 };

      } else if (state.camMode === CAM_MODES.SATELLITE) {
        // Space orbital perspective
        targetLook = { x: playerWorld.x, y: playerWorld.y, z: playerWorld.z };
        targetCam = { x: playerWorld.x + 180, y: playerWorld.y + 500, z: playerWorld.z + 240 };
      }

      // Smooth camera interpolation
      state.cam.x += (targetCam.x - state.cam.x) * 0.14;
      state.cam.y += (targetCam.y - state.cam.y) * 0.14;
      state.cam.z += (targetCam.z - state.cam.z) * 0.14;

      state.target.x += (targetLook.x - state.target.x) * 0.14;
      state.target.y += (targetLook.y - state.target.y) * 0.14;
      state.target.z += (targetLook.z - state.target.z) * 0.14;

      // Clear frame
      ctx.clearRect(0, 0, state.W, state.H);

      // 1. Starfield
      renderStars(state.cam, state.target);

      // 2. Mountains & Contour Elevation Mesh
      renderMountains(state.cam, state.target, baseS);

      // 3. 3D Winding Road Ribbon
      renderRoad(state.cam, state.target, baseS);

      // 4. Mountain Tunnel Portal
      renderTunnel(state.cam, state.target);

      // 5. Low-Earth Orbit Satellite
      renderSatellite(state.cam, state.target, state.simTime);

      // 6. Tactical Radar Sphere (when in Radar Mode)
      renderRadarSphere(state.cam, state.target, state.simTime, playerWorld);

      // 7. Collective Road Hazard AI
      renderHazard(state.cam, state.target, state.simTime);

      // 8. Convoy Motorcycles
      var riderWorldCoords = [];
      for (var r = 0; r < RIDERS.length; r++) {
        var rider = RIDERS[r];
        var sPos = baseS + rider.offsetS;
        var rWorld = roadSpline(sPos);
        var rTan = roadTangent(sPos);
        rWorld.y += 2.2;
        riderWorldCoords.push(rWorld);

        renderMotorcycle(rider, rWorld, rTan, state.cam, state.target, state.simTime, r === 1);
      }

      // 9. Living P2P Bluetooth Mesh Web
      renderMeshWeb(riderWorldCoords, state.cam, state.target, state.simTime);

      // 10. First-Person Helmet Cockpit & Handlebar HUD
      renderCockpitHUD();

      win.requestAnimationFrame(frame);
    }

    
    // Live Convoy Telemetry Dashboard Driver
    function initLiveDashboard() {
      var toggleBtn = doc.getElementById('dash-toggle-btn');
      var dashCard = doc.querySelector('.dash-card');
      if (toggleBtn && dashCard) {
        toggleBtn.addEventListener('click', function () {
          var isMin = dashCard.classList.toggle('is-minimized');
          toggleBtn.setAttribute('aria-expanded', isMin ? 'false' : 'true');
          var textSpan = toggleBtn.querySelector('.dash-toggle-text');
          if (textSpan) textSpan.textContent = isMin ? 'EXPAND' : 'MINIMIZE';
        });
      }

      var liveRiders = 1428;
      var totalTrips = 48920;
      var totalKms = 1842650.4;
      var longestKm = 1280;

      function formatNum(n) {
        return Math.floor(n).toLocaleString('en-US');
      }

      var elRiders = doc.getElementById('stat-live-riders');
      var elTrips = doc.getElementById('stat-total-trips');
      var elKms = doc.getElementById('stat-total-kms');
      var elLongest = doc.getElementById('stat-longest-km');
      var elHeroRiders = doc.getElementById('hero-stat-riders');
      var elHeroTrips = doc.getElementById('hero-stat-trips');
      var elHeroKms = doc.getElementById('hero-stat-kms');
      var elHeroLongest = doc.getElementById('hero-stat-longest');
      var elSpeed = doc.getElementById('dash-avg-speed');

      function updateDashboardStats() {
        var delta = (Math.random() > 0.48 ? 1 : -1) * Math.floor(Math.random() * 3 + 1);
        liveRiders = Math.max(1415, Math.min(1445, liveRiders + delta));
        
        totalKms += (state.simSpeed * 0.4);
        if (Math.random() > 0.85) totalTrips += 1;

        if (elRiders) elRiders.textContent = formatNum(liveRiders);
        if (elTrips) elTrips.textContent = formatNum(totalTrips);
        if (elKms) elKms.textContent = formatNum(totalKms);
        if (elLongest) elLongest.textContent = formatNum(longestKm) + ' KM';

        if (elHeroRiders) elHeroRiders.textContent = formatNum(liveRiders);
        if (elHeroTrips) elHeroTrips.textContent = formatNum(totalTrips);
        if (elHeroKms) elHeroKms.textContent = formatNum(totalKms) + ' KM';
        if (elHeroLongest) elHeroLongest.textContent = formatNum(longestKm) + ' KM';

        if (elSpeed) elSpeed.textContent = Math.round(54 + Math.sin(state.simTime) * 6) + ' km/h';
      }

      setInterval(updateDashboardStats, 3500);
      updateDashboardStats();
    }
    initLiveDashboard();

    win.requestAnimationFrame(frame);
  }

  // Self-initialize on DOM ready
  if (doc.readyState === 'loading') {
    doc.addEventListener('DOMContentLoaded', initWorld3D);
  } else {
    initWorld3D();
  }
})();
