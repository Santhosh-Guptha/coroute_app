/* ==========================================================================
   CoRoute Interactive 3D Convoy Cockpit & Radar Sphere
   Pure Canvas 2D Perspective Engine with Matrix Projection.
   Lightweight (<20KB), Zero External Dependencies, 60 FPS, Dark Mode.
   ========================================================================== */

(function () {
  'use strict';

  var doc = document;
  var win = window;

  function init3DCockpit() {
    var stage = doc.getElementById('cockpit-stage');
    var canvas = doc.getElementById('cockpit-canvas');
    if (!stage || !canvas) return;

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

    // View & Camera State
    var state = {
      W: 1200,
      H: 640,
      dpr: 1,
      viewMode: 'corridor', // 'corridor' | 'radar' | 'mesh'
      yaw: 0.65,            // Camera azimuth angle (radians)
      pitch: 0.42,          // Camera tilt angle (radians)
      dist: 380,            // Camera distance
      targetDist: 380,
      vx: 0,
      vy: 0,
      isDragging: false,
      lastX: 0,
      lastY: 0,
      dragDist: 0,
      autoRotate: true,
      autoRotateTimer: null,
      simTime: 0,
      simSpeed: 1.0,
      gyroActive: false,
      gyroYaw: 0,
      gyroPitch: 0,
      selectedNode: -1,
      hoveredNode: -1
    };

    var prefersReduced = win.matchMedia && win.matchMedia('(prefers-reduced-motion: reduce)').matches;
    if (prefersReduced) {
      state.autoRotate = false;
    }

    // Color Palette matching CoRoute Theme
    var PALETTE = {
      bg: '#0B0D0E',
      surface: '#121516',
      grid: 'rgba(255, 255, 255, 0.05)',
      gridAccent: 'rgba(62, 224, 236, 0.12)',
      road: '#1A1E20',
      roadEdge: '#363C3F',
      routeLine: '#FF6F2E',
      routeGlow: 'rgba(255, 111, 46, 0.4)',
      dash: 'rgba(242, 238, 231, 0.4)',
      radarRing: 'rgba(62, 224, 236, 0.22)',
      radarBeam: 'rgba(62, 224, 236, 0.15)',
      meshLink: 'rgba(79, 209, 139, 0.35)',
      meshPacket: '#4FD18B',
      text: '#F2EEE7',
      textMuted: '#8A867F',
      cyan: '#3EE0EC',
      amber: '#FFB347',
      orange: '#FF6F2E',
      green: '#4FD18B',
      red: '#FF4D4A'
    };

    // Convoy Rider Nodes along the mountain pass
    var RIDERS = [
      { id: 'AK', callsign: 'AK', role: 'Lead', baseS: 120, col: PALETTE.amber, glow: 'rgba(255, 179, 71,', speed: '62 km/h', dist: '+850 m', pulse: 0 },
      { id: 'YOU', callsign: 'You', role: 'Center', baseS: 35, col: PALETTE.orange, glow: 'rgba(255, 111, 46,', speed: '61 km/h', dist: '0 m', pulse: 1.2 },
      { id: 'RS', callsign: 'RS', role: 'Pack', baseS: -40, col: PALETTE.cyan, glow: 'rgba(62, 224, 236,', speed: '59 km/h', dist: '-600 m', pulse: 2.4 },
      { id: 'PJ', callsign: 'PJ', role: 'Scout', baseS: -115, col: PALETTE.green, glow: 'rgba(79, 209, 139,', speed: '63 km/h', dist: '-1.4 km', pulse: 3.6 },
      { id: 'MV', callsign: 'MV', role: 'Sweeper', baseS: -190, col: PALETTE.orange, glow: 'rgba(255, 111, 46,', speed: '58 km/h', dist: '-2.1 km', pulse: 4.8 }
    ];

    // Road Hazard Marker (Pothole / wet gravel detected 300m ahead of 'You')
    var HAZARD = {
      baseS: 75,
      type: 'POTHOLE & GRAVEL',
      distText: '300m ahead',
      col: PALETTE.amber
    };

    // Mathematical Spline for the 3D Mountain Pass Corridor
    function roadCurve(s) {
      var x = 85 * Math.sin(s * 0.014) + 30 * Math.sin(s * 0.038);
      var y = 22 * Math.sin(s * 0.012) + 40 * (s / 320); // Elevation climb up ghat pass
      var z = s;
      return { x: x, y: y, z: z };
    }

    // 3D Perspective Projection Function
    function project3D(x, y, z) {
      // Rotation around Y (Yaw)
      var cosY = Math.cos(state.yaw);
      var sinY = Math.sin(state.yaw);
      var x1 = x * cosY + z * sinY;
      var z1 = -x * sinY + z * cosY;

      // Rotation around X (Pitch)
      var cosP = Math.cos(state.pitch);
      var sinP = Math.sin(state.pitch);
      var y2 = y * cosP - z1 * sinP;
      var z2 = y * sinP + z1 * cosP + state.dist;

      if (z2 < 10) z2 = 10; // Prevent divide by zero / clip behind camera

      var fov = Math.min(state.W, state.H) * 1.05;
      var scale = fov / z2;
      var screenX = state.W / 2 + x1 * scale;
      var screenY = state.H / 2 - y2 * scale;

      return {
        x: screenX,
        y: screenY,
        z: z2,
        scale: scale,
        visible: z2 > 15 && screenX > -150 && screenX < state.W + 150 && screenY > -150 && screenY < state.H + 150
      };
    }

    // Resize Handler with Retina / 4K DPI scaling
    function handleResize() {
      state.W = stage.clientWidth || 1200;
      state.H = stage.clientHeight || 640;
      state.dpr = Math.min(win.devicePixelRatio || 1, 2);
      canvas.width = Math.round(state.W * state.dpr);
      canvas.height = Math.round(state.H * state.dpr);
      ctx.setTransform(state.dpr, 0, 0, state.dpr, 0, 0);
    }
    handleResize();
    win.addEventListener('resize', handleResize, { passive: true });

    // Pointer Events for Drag & Orbit
    function onPointerDown(e) {
      state.isDragging = true;
      state.autoRotate = false;
      state.dragDist = 0;
      state.lastX = e.clientX;
      state.lastY = e.clientY;
      state.vx = 0;
      state.vy = 0;
      clearTimeout(state.autoRotateTimer);
    }

    function onPointerMove(e) {
      if (!state.isDragging) {
        // Check hover over rider nodes
        var rect = canvas.getBoundingClientRect();
        var mx = e.clientX - rect.left;
        var my = e.clientY - rect.top;
        checkNodeHover(mx, my);
        return;
      }

      var dx = e.clientX - state.lastX;
      var dy = e.clientY - state.lastY;
      state.dragDist += Math.abs(dx) + Math.abs(dy);

      state.vx = dx * 0.005;
      state.vy = dy * 0.005;

      state.yaw += state.vx;
      state.pitch = Math.max(0.1, Math.min(1.45, state.pitch + state.vy));

      state.lastX = e.clientX;
      state.lastY = e.clientY;
    }

    function onPointerUp(e) {
      if (state.isDragging && state.dragDist < 6) {
        // Quick tap: select clicked node
        var rect = canvas.getBoundingClientRect();
        var mx = e.clientX - rect.left;
        var my = e.clientY - rect.top;
        checkNodeClick(mx, my);
      }

      state.isDragging = false;
      clearTimeout(state.autoRotateTimer);
      if (!prefersReduced) {
        state.autoRotateTimer = setTimeout(function () {
          state.autoRotate = true;
        }, 2500);
      }
    }

    canvas.addEventListener('pointerdown', onPointerDown);
    win.addEventListener('pointermove', onPointerMove, { passive: true });
    win.addEventListener('pointerup', onPointerUp, { passive: true });
    win.addEventListener('pointercancel', onPointerUp, { passive: true });

    // Wheel Zoom
    canvas.addEventListener('wheel', function (e) {
      e.preventDefault();
      state.targetDist = Math.max(200, Math.min(600, state.targetDist + e.deltaY * 0.4));
      state.autoRotate = false;
      clearTimeout(state.autoRotateTimer);
      state.autoRotateTimer = setTimeout(function () { state.autoRotate = true; }, 3000);
    }, { passive: false });

    // Keyboard Accessibility (arrow keys to orbit, +/- to zoom)
    stage.addEventListener('keydown', function (e) {
      if (e.key === 'ArrowLeft') { state.yaw -= 0.06; e.preventDefault(); }
      else if (e.key === 'ArrowRight') { state.yaw += 0.06; e.preventDefault(); }
      else if (e.key === 'ArrowUp') { state.pitch = Math.min(1.45, state.pitch + 0.05); e.preventDefault(); }
      else if (e.key === 'ArrowDown') { state.pitch = Math.max(0.1, state.pitch - 0.05); e.preventDefault(); }
      else if (e.key === '+' || e.key === '=') { state.targetDist = Math.max(200, state.targetDist - 30); e.preventDefault(); }
      else if (e.key === '-' || e.key === '_') { state.targetDist = Math.min(600, state.targetDist + 30); e.preventDefault(); }
    });

    // Mobile Gyroscope / DeviceOrientation Listener
    function onDeviceOrientation(e) {
      if (e.gamma !== null && e.beta !== null) {
        state.gyroActive = true;
        // Map tilt to gentle yaw/pitch offset
        state.gyroYaw = (e.gamma || 0) * 0.008;
        state.gyroPitch = ((e.beta || 45) - 45) * 0.006;
      }
    }
    if (win.DeviceOrientationEvent) {
      win.addEventListener('deviceorientation', onDeviceOrientation, { passive: true });
    }

    // Interactive Node Click/Hover Detection
    var projectedNodes = [];
    function checkNodeHover(mx, my) {
      var found = -1;
      for (var i = 0; i < projectedNodes.length; i++) {
        var node = projectedNodes[i];
        if (!node.visible) continue;
        var dx = mx - node.x;
        var dy = my - node.y;
        if (dx * dx + dy * dy < 28 * 28) {
          found = i;
          break;
        }
      }
      state.hoveredNode = found;
      canvas.style.cursor = found >= 0 ? 'pointer' : (state.isDragging ? 'grabbing' : 'grab');
    }

    function checkNodeClick(mx, my) {
      checkNodeHover(mx, my);
      state.selectedNode = state.hoveredNode;
    }

    // View Mode Buttons
    var modeBtns = doc.querySelectorAll('.cockpit-mode-btn');
    modeBtns.forEach(function (btn) {
      btn.addEventListener('click', function () {
        modeBtns.forEach(function (b) {
          b.classList.remove('is-active');
          b.setAttribute('aria-selected', 'false');
        });
        btn.classList.add('is-active');
        btn.setAttribute('aria-selected', 'true');
        state.viewMode = btn.getAttribute('data-view') || 'corridor';
      });
    });

    // Action Controls: Reset View
    var resetBtn = doc.getElementById('cockpit-reset');
    if (resetBtn) {
      resetBtn.addEventListener('click', function () {
        state.yaw = 0.65;
        state.pitch = 0.42;
        state.targetDist = 380;
        state.vx = 0;
        state.vy = 0;
        state.selectedNode = -1;
      });
    }

    // Action Controls: Gyroscope Toggle
    var gyroBtn = doc.getElementById('cockpit-gyro');
    var gyroStatus = doc.getElementById('gyro-status');
    var gyroManualEnabled = true;
    if (gyroBtn) {
      gyroBtn.addEventListener('click', function () {
        gyroManualEnabled = !gyroManualEnabled;
        if (gyroStatus) {
          gyroStatus.textContent = gyroManualEnabled ? 'Gyro: Active' : 'Gyro: Off';
        }
      });
    }

    // Action Controls: Simulation Speed Toggle
    var pauseBtn = doc.getElementById('cockpit-pause');
    var pauseStatus = doc.getElementById('pause-status');
    if (pauseBtn) {
      pauseBtn.addEventListener('click', function () {
        if (state.simSpeed > 0) {
          state.simSpeed = 0;
          if (pauseStatus) pauseStatus.textContent = 'Sim: Paused';
        } else {
          state.simSpeed = 1.0;
          if (pauseStatus) pauseStatus.textContent = 'Sim: 60 km/h';
        }
      });
    }

    // =========================================================================
    // Render Functions
    // =========================================================================

    // 1. Draw Topographical Mountain Ridge Contours
    function drawTerrain(t) {
      if (state.viewMode === 'radar') return;

      var step = 28;
      var halfWidth = 240;
      var numLines = 26;

      ctx.save();
      for (var i = -numLines / 2; i <= numLines / 2; i++) {
        var s = i * step;
        var center = roadCurve(s);

        // Cross-section contour lines perpendicular to the road corridor
        var pts = [];
        var samples = 14;
        for (var j = -samples / 2; j <= samples / 2; j++) {
          var u = (j / (samples / 2)) * halfWidth;
          var distFromRoad = Math.abs(u);

          // Mountain elevation profile (higher ridges away from the road corridor)
          var ridgeElevation = Math.max(0, distFromRoad - 35) * 0.45;
          var noise = 8 * Math.sin(u * 0.04 + s * 0.02) + 5 * Math.cos(s * 0.05);
          var elev = center.y - 12 + ridgeElevation + noise;

          var pt = project3D(center.x + u, elev, s);
          pts.push(pt);
        }

        // Render Contour Wire
        ctx.beginPath();
        var started = false;
        for (var k = 0; k < pts.length; k++) {
          if (pts[k].visible) {
            if (!started) {
              ctx.moveTo(pts[k].x, pts[k].y);
              started = true;
            } else {
              ctx.lineTo(pts[k].x, pts[k].y);
            }
          }
        }

        var alpha = Math.max(0.04, 0.22 - Math.abs(i) / (numLines * 1.6));
        ctx.strokeStyle = state.viewMode === 'corridor' ? 'rgba(62, 224, 236, ' + alpha.toFixed(3) + ')' : PALETTE.grid;
        ctx.lineWidth = 1;
        ctx.stroke();
      }
      ctx.restore();
    }

    // 2. Draw 3D Road Ribbon and Route Line
    function drawRoadCorridor(t) {
      var steps = 120;
      var sMin = -320;
      var sMax = 320;
      var roadHalfW = 8.5;

      var leftEdge = [];
      var rightEdge = [];
      var centerLine = [];
      var routeLine = [];

      for (var i = 0; i <= steps; i++) {
        var s = sMin + (i / steps) * (sMax - sMin);
        var pt = roadCurve(s);

        // Approximate tangent & normal in XZ plane
        var ds = 1.0;
        var pNext = roadCurve(s + ds);
        var dx = pNext.x - pt.x;
        var dz = pNext.z - pt.z;
        var len = Math.sqrt(dx * dx + dz * dz) || 1;
        var nx = -dz / len;
        var nz = dx / len;

        var l = project3D(pt.x + nx * roadHalfW, pt.y, pt.z + nz * roadHalfW);
        var r = project3D(pt.x - nx * roadHalfW, pt.y, pt.z - nz * roadHalfW);
        var c = project3D(pt.x, pt.y + 0.3, pt.z);
        var rt = project3D(pt.x - nx * 3.2, pt.y + 0.4, pt.z - nz * 3.2);

        leftEdge.push(l);
        rightEdge.push(r);
        centerLine.push(c);
        routeLine.push(rt);
      }

      ctx.save();

      // Road Surface polygon
      ctx.beginPath();
      var started = false;
      for (var i = 0; i < leftEdge.length; i++) {
        if (leftEdge[i].visible) {
          if (!started) { ctx.moveTo(leftEdge[i].x, leftEdge[i].y); started = true; }
          else { ctx.lineTo(leftEdge[i].x, leftEdge[i].y); }
        }
      }
      for (var i = rightEdge.length - 1; i >= 0; i--) {
        if (rightEdge[i].visible) {
          ctx.lineTo(rightEdge[i].x, rightEdge[i].y);
        }
      }
      ctx.closePath();
      ctx.fillStyle = PALETTE.road;
      ctx.fill();

      // Road Edge Stripes
      function strokeEdge(edge, col, width) {
        ctx.beginPath();
        var st = false;
        for (var i = 0; i < edge.length; i++) {
          if (edge[i].visible) {
            if (!st) { ctx.moveTo(edge[i].x, edge[i].y); st = true; }
            else { ctx.lineTo(edge[i].x, edge[i].y); }
          }
        }
        ctx.strokeStyle = col;
        ctx.lineWidth = width;
        ctx.stroke();
      }

      strokeEdge(leftEdge, PALETTE.roadEdge, 1.2);
      strokeEdge(rightEdge, PALETTE.roadEdge, 1.2);

      // Glowing Route Line (Orange)
      ctx.shadowColor = PALETTE.routeGlow;
      ctx.shadowBlur = 12;
      strokeEdge(routeLine, PALETTE.routeLine, 3.2);
      ctx.shadowBlur = 0;

      // Dashed Centerline
      ctx.setLineDash([8, 12]);
      strokeEdge(centerLine, PALETTE.dash, 1.0);
      ctx.setLineDash([]);

      ctx.restore();
    }

    // 3. Draw 3D Spherical Radar Grid & Sweep Beam
    function drawRadarSphere(t) {
      if (state.viewMode === 'corridor') return;

      ctx.save();
      var center = project3D(0, 0, 0);
      var radii = [
        { r: 70, label: '1.0 KM', alpha: 0.35 },
        { r: 160, label: '2.5 KM', alpha: 0.28 },
        { r: 260, label: '5.0 KM', alpha: 0.20 }
      ];

      // Concentric Radar Rings in 3D XZ ground plane
      radii.forEach(function (ring) {
        var pts = [];
        var segments = 64;
        for (var i = 0; i <= segments; i++) {
          var theta = (i / segments) * Math.PI * 2;
          var rx = ring.r * Math.cos(theta);
          var rz = ring.r * Math.sin(theta);
          var pt = project3D(rx, 0, rz);
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
        ctx.strokeStyle = 'rgba(62, 224, 236, ' + ring.alpha + ')';
        ctx.lineWidth = 1;
        ctx.stroke();

        // Range Label
        var lblPt = project3D(ring.r * 0.95, 0, 0);
        if (lblPt.visible) {
          ctx.fillStyle = PALETTE.cyan;
          ctx.font = '9px ' + (doc.body.style.fontFamily || 'monospace');
          ctx.fillText(ring.label, lblPt.x + 4, lblPt.y - 2);
        }
      });

      // Rotating Radar Sweep Beam
      var sweepAngle = (t * 1.6) % (Math.PI * 2);
      var beamSegments = 16;
      var sweepSpan = 0.45; // Beam angle width

      ctx.beginPath();
      var origin = project3D(0, 0, 0);
      if (origin.visible) {
        ctx.moveTo(origin.x, origin.y);
        for (var i = 0; i <= beamSegments; i++) {
          var a = sweepAngle - (i / beamSegments) * sweepSpan;
          var edgePt = project3D(260 * Math.cos(a), 0, 260 * Math.sin(a));
          if (edgePt.visible) ctx.lineTo(edgePt.x, edgePt.y);
        }
        ctx.closePath();
        ctx.fillStyle = PALETTE.radarBeam;
        ctx.fill();
      }

      // Sweep Edge Line
      var leadEdgePt = project3D(260 * Math.cos(sweepAngle), 0, 260 * Math.sin(sweepAngle));
      if (origin.visible && leadEdgePt.visible) {
        ctx.beginPath();
        ctx.moveTo(origin.x, origin.y);
        ctx.lineTo(leadEdgePt.x, leadEdgePt.y);
        ctx.strokeStyle = PALETTE.cyan;
        ctx.lineWidth = 1.5;
        ctx.stroke();
      }

      ctx.restore();
    }

    // 4. Draw Animated P2P Bluetooth Mesh Web
    function drawMeshWeb(t, riderPos) {
      ctx.save();
      // Links between adjacent & near convoy nodes
      var links = [
        [0, 1], // AK <-> YOU
        [1, 2], // YOU <-> RS
        [2, 3], // RS <-> PJ
        [3, 4], // PJ <-> MV (Sweeper)
        [1, 3]  // Multi-hop redundant bridge YOU <-> PJ
      ];

      links.forEach(function (pair, idx) {
        var r1 = riderPos[pair[0]];
        var r2 = riderPos[pair[1]];
        if (!r1 || !r2 || !r1.visible || !r2.visible) return;

        // Mesh Link Line
        ctx.beginPath();
        ctx.moveTo(r1.x, r1.y);
        ctx.lineTo(r2.x, r2.y);
        ctx.strokeStyle = PALETTE.meshLink;
        ctx.lineWidth = 1.2;
        ctx.stroke();

        // Animated Hop Packets (glowing data pulse flying along mesh line)
        var packetT = (t * 1.8 + idx * 0.28) % 1.0;
        var px = r1.x + (r2.x - r1.x) * packetT;
        var py = r1.y + (r2.y - r1.y) * packetT;

        ctx.beginPath();
        ctx.arc(px, py, 3.2, 0, Math.PI * 2);
        ctx.fillStyle = PALETTE.meshPacket;
        ctx.shadowColor = PALETTE.meshPacket;
        ctx.shadowBlur = 8;
        ctx.fill();
        ctx.shadowBlur = 0;
      });

      ctx.restore();
    }

    // 5. Draw Glowing Rider Nodes and Telemetry Badges
    function drawRiderNodes(t, riderPos) {
      projectedNodes = [];

      for (var i = 0; i < RIDERS.length; i++) {
        var rider = RIDERS[i];
        var pt = riderPos[i];
        projectedNodes.push(pt);
        if (!pt.visible) continue;

        var isSelected = state.selectedNode === i || state.hoveredNode === i;
        var nodeRad = Math.max(5, Math.min(14, 8 * pt.scale));

        ctx.save();

        // Ground Altitude Drop Line & Shadow
        var groundPt = project3D(pt.worldX, pt.worldY - 8, pt.worldZ);
        if (groundPt.visible) {
          ctx.beginPath();
          ctx.moveTo(pt.x, pt.y);
          ctx.lineTo(groundPt.x, groundPt.y);
          ctx.strokeStyle = 'rgba(255, 255, 255, 0.18)';
          ctx.lineWidth = 1;
          ctx.setLineDash([2, 4]);
          ctx.stroke();
          ctx.setLineDash([]);

          ctx.beginPath();
          ctx.arc(groundPt.x, groundPt.y, nodeRad * 0.7, 0, Math.PI * 2);
          ctx.fillStyle = 'rgba(0, 0, 0, 0.4)';
          ctx.fill();
        }

        // Concentric Radio Pulse Wave Ring
        var pulseProgress = (t * 1.4 + rider.pulse) % 1.0;
        var pulseRadius = nodeRad + pulseProgress * 22;
        var pulseAlpha = Math.max(0, 0.7 * (1 - pulseProgress));

        ctx.beginPath();
        ctx.arc(pt.x, pt.y, pulseRadius, 0, Math.PI * 2);
        ctx.strokeStyle = rider.glow + pulseAlpha + ')';
        ctx.lineWidth = 1.5;
        ctx.stroke();

        // Node Glow Halo
        ctx.beginPath();
        ctx.arc(pt.x, pt.y, nodeRad, 0, Math.PI * 2);
        ctx.fillStyle = rider.col;
        ctx.shadowColor = rider.col;
        ctx.shadowBlur = isSelected ? 18 : 10;
        ctx.fill();
        ctx.shadowBlur = 0;

        // Node Center Core
        ctx.beginPath();
        ctx.arc(pt.x, pt.y, nodeRad * 0.45, 0, Math.PI * 2);
        ctx.fillStyle = '#FFFFFF';
        ctx.fill();

        // 3D Callsign Tag Badge
        var badgeY = pt.y - nodeRad - 12;
        var badgeText = rider.callsign + ' (' + rider.role + ')';
        ctx.font = 'bold 11px ' + (doc.body.style.fontFamily || 'sans-serif');
        var textW = ctx.measureText(badgeText).width;

        // Badge Background Chip
        ctx.fillStyle = isSelected ? 'rgba(25, 29, 30, 0.95)' : 'rgba(18, 21, 22, 0.85)';
        ctx.strokeStyle = isSelected ? rider.col : 'rgba(255, 255, 255, 0.15)';
        ctx.lineWidth = 1;
        ctx.beginPath();
        ctx.roundRect(pt.x - textW / 2 - 6, badgeY - 14, textW + 12, 18, 4);
        ctx.fill();
        ctx.stroke();

        // Badge Text
        ctx.fillStyle = isSelected ? '#FFFFFF' : PALETTE.text;
        ctx.textAlign = 'center';
        ctx.fillText(badgeText, pt.x, badgeY);

        // Expanded Interactive Telemetry Card on Selection/Hover
        if (isSelected) {
          var cardW = 160;
          var cardH = 74;
          var cardX = pt.x + 16;
          var cardY = pt.y - cardH / 2;

          // Prevent edge overflow
          if (cardX + cardW > state.W - 12) cardX = pt.x - cardW - 16;
          if (cardY < 12) cardY = 12;

          ctx.fillStyle = 'rgba(11, 13, 14, 0.94)';
          ctx.strokeStyle = rider.col;
          ctx.lineWidth = 1.5;
          ctx.beginPath();
          ctx.roundRect(cardX, cardY, cardW, cardH, 6);
          ctx.fill();
          ctx.stroke();

          ctx.textAlign = 'left';
          ctx.font = 'bold 11px monospace';
          ctx.fillStyle = rider.col;
          ctx.fillText(rider.callsign + ' ' + rider.dist, cardX + 10, cardY + 16);

          ctx.font = '10px monospace';
          ctx.fillStyle = PALETTE.text;
          ctx.fillText('SPEED: ' + rider.speed, cardX + 10, cardY + 32);
          ctx.fillText('STATUS: P2P MESH (0-HOP)', cardX + 10, cardY + 46);
          ctx.fillStyle = PALETTE.cyan;
          ctx.fillText('BLE AIRBAG: SYNCED', cardX + 10, cardY + 60);
        }

        ctx.restore();
      }
    }

    // 6. Draw Collective Road Hazard Marker
    function drawRoadHazard(t) {
      var hPos = roadCurve(HAZARD.baseS);
      var pt = project3D(hPos.x, hPos.y + 0.8, hPos.z);
      if (!pt.visible) return;

      ctx.save();

      // Pulsing Danger Circle on Road
      var pulse = (t * 2.0) % 1.0;
      var r = 10 + pulse * 24;
      ctx.beginPath();
      ctx.arc(pt.x, pt.y, r, 0, Math.PI * 2);
      ctx.strokeStyle = 'rgba(255, 179, 71, ' + (1 - pulse) + ')';
      ctx.lineWidth = 1.5;
      ctx.stroke();

      // Diamond Warning Icon
      ctx.beginPath();
      ctx.moveTo(pt.x, pt.y - 9);
      ctx.lineTo(pt.x + 9, pt.y);
      ctx.lineTo(pt.x, pt.y + 9);
      ctx.lineTo(pt.x - 9, pt.y);
      ctx.closePath();
      ctx.fillStyle = PALETTE.amber;
      ctx.fill();

      // Exclamation Mark inside diamond
      ctx.fillStyle = '#0B0D0E';
      ctx.font = 'bold 11px sans-serif';
      ctx.textAlign = 'center';
      ctx.fillText('!', pt.x, pt.y + 4);

      // Warning Label
      ctx.font = 'bold 9px monospace';
      ctx.fillStyle = PALETTE.amber;
      ctx.fillText('HAZARD: 300M', pt.x, pt.y - 14);

      ctx.restore();
    }

    // =========================================================================
    // Main 60 FPS Animation Loop
    // =========================================================================
    var lastTime = performance.now();
    var isVisible = true;

    function renderLoop(now) {
      if (!isVisible) {
        lastTime = now;
        win.requestAnimationFrame(renderLoop);
        return;
      }

      var dt = Math.min(0.08, (now - lastTime) / 1000);
      lastTime = now;

      // Update Simulation Clock
      state.simTime += dt * state.simSpeed;

      // Apply Inertia & Friction
      if (!state.isDragging) {
        state.yaw += state.vx;
        state.pitch = Math.max(0.1, Math.min(1.45, state.pitch + state.vy));
        state.vx *= 0.92;
        state.vy *= 0.92;

        // Smooth Auto-orbit when idle
        if (state.autoRotate) {
          state.yaw += dt * 0.12;
        }
      }

      // Smooth Camera Zoom lerp
      state.dist += (state.targetDist - state.dist) * 0.12;

      // Smooth Gyroscope blend
      if (state.gyroActive && gyroManualEnabled) {
        state.yaw += (state.gyroYaw * 0.05);
        state.pitch = Math.max(0.1, Math.min(1.45, state.pitch + state.gyroPitch * 0.05));
      }

      // Clear Canvas Frame
      ctx.clearRect(0, 0, state.W, state.H);

      // 1. Terrain & Ridges
      drawTerrain(state.simTime);

      // 2. Road Corridor Ribbon
      drawRoadCorridor(state.simTime);

      // 3. Radar Sphere Grid & Sweep
      drawRadarSphere(state.simTime);

      // Compute Current Rider Positions along Curve
      var riderPositions = RIDERS.map(function (r, idx) {
        // Subtle convoy pacing & drift
        var offsetS = r.baseS + 4 * Math.sin(state.simTime * 0.4 + idx * 1.3);
        var world = roadCurve(offsetS);
        // Slight lateral lane sway
        world.x += 1.8 * Math.sin(state.simTime * 0.6 + idx * 2.1);
        var pt = project3D(world.x, world.y + 2.5, world.z);
        pt.worldX = world.x;
        pt.worldY = world.y + 2.5;
        pt.worldZ = world.z;
        return pt;
      });

      // 4. P2P Mesh Web
      drawMeshWeb(state.simTime, riderPositions);

      // 5. Road Hazard AI Alert
      drawRoadHazard(state.simTime);

      // 6. Glowing Rider Nodes & Badges
      drawRiderNodes(state.simTime, riderPositions);

      win.requestAnimationFrame(renderLoop);
    }

    // IntersectionObserver to pause loop when scrolled away (0 CPU cost)
    if ('IntersectionObserver' in win) {
      var io = new IntersectionObserver(function (entries) {
        isVisible = entries[0].isIntersecting;
      }, { threshold: 0.1 });
      io.observe(stage);
    }

    // Start 60 FPS Render Loop
    win.requestAnimationFrame(renderLoop);
  }

  // Self-initialize on DOM ready
  if (doc.readyState === 'loading') {
    doc.addEventListener('DOMContentLoaded', init3DCockpit);
  } else {
    init3DCockpit();
  }
})();
