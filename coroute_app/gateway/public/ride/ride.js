/* CoRoute ride in a browser (v3.63, gateway src/guest_service.js). No app, no account: a first name, the host lets
   you in, then the group map, your position shared while this page is open, SOS alerts with sound and vibration,
   and an SOS button (hold 3 s). Text is set as text only (no HTML strings). ES2019 (old iPhones). */
(function () {
  'use strict';
  var $ = function (id) { return document.getElementById(id); };
  var m = /^\/ride\/([A-Za-z0-9]{4,10})\/?$/.exec(location.pathname);
  var CODE = m ? m[1].toUpperCase() : '';
  var store = {
    get: function (k) { try { return localStorage.getItem(k); } catch (e) { return null; } },
    set: function (k, v) { try { if (v === null) localStorage.removeItem(k); else localStorage.setItem(k, v); } catch (e) { /* private mode */ } }
  };
  var TOKEN_KEY = 'cr.guest.' + CODE;
  var st = { token: store.get(TOKEN_KEY), status: '', seen: {}, map: null, layers: {}, myPos: null, lastSent: null, lastSentAt: 0, watch: null, wake: null, poll: null, mySos: null, fitted: false, sosTimer: null, audio: null, beep: null, pending: null };

  function deviceId() {
    var d = store.get('cr.guest.device');
    if (!d || !/^[A-Za-z0-9_-]{16,64}$/.test(d)) {
      var a = new Uint8Array(18); (window.crypto || window.msCrypto).getRandomValues(a);
      d = Array.prototype.map.call(a, function (x) { return ('0' + x.toString(16)).slice(-2); }).join('');
      store.set('cr.guest.device', d);
    }
    return d;
  }
  function show(view) {
    ['view-join', 'view-wait', 'view-end', 'view-ride'].forEach(function (v) { $(v).hidden = v !== view; });
  }
  function toast(text) {
    var t = $('toast'); t.textContent = text; t.hidden = false;
    clearTimeout(toast.t); toast.t = setTimeout(function () { t.hidden = true; }, 3500);
  }
  function api(method, path, body) {
    var h = { 'Content-Type': 'application/json' };
    if (st.token) h.Authorization = 'Bearer ' + st.token;
    return fetch('/api/guest' + path, { method: method, headers: h, body: body ? JSON.stringify(body) : undefined, cache: 'no-store', credentials: 'omit' })
      .then(function (r) { return r.json().catch(function () { return {}; }).then(function (j) { j._status = r.status; return j; }); });
  }
  function ago(ms) {
    var s = Math.max(0, Math.round((Date.now() - ms) / 1000));
    if (!ms) return 'no position yet';
    if (s < 60) return 'now'; if (s < 3600) return Math.round(s / 60) + ' min ago'; return Math.round(s / 3600) + ' h ago';
  }
  function distKm(a, b) {
    var R = 6371, dLat = (b.lat - a.lat) * Math.PI / 180, dLng = (b.lng - a.lng) * Math.PI / 180;
    var x = Math.sin(dLat / 2) * Math.sin(dLat / 2) + Math.cos(a.lat * Math.PI / 180) * Math.cos(b.lat * Math.PI / 180) * Math.sin(dLng / 2) * Math.sin(dLng / 2);
    return 2 * R * Math.atan2(Math.sqrt(x), Math.sqrt(1 - x));
  }
  function decodePolyline(str) {
    var out = [], i = 0, lat = 0, lng = 0;
    while (i < str.length && out.length < 20000) {
      var b, shift = 0, res = 0;
      do { b = str.charCodeAt(i++) - 63; res |= (b & 31) << shift; shift += 5; } while (b >= 32 && i < str.length);
      lat += (res & 1) ? ~(res >> 1) : (res >> 1);
      shift = 0; res = 0;
      do { b = str.charCodeAt(i++) - 63; res |= (b & 31) << shift; shift += 5; } while (b >= 32 && i < str.length);
      lng += (res & 1) ? ~(res >> 1) : (res >> 1);
      out.push([lat / 1e5, lng / 1e5]);
    }
    return out;
  }

  /* ---------- join ---------- */
  function startJoin(ev) {
    if (ev) ev.preventDefault();
    var name = $('join-name').value.trim();
    var err = $('join-err');
    err.hidden = true;
    if (!name) { err.textContent = 'Enter your first name.'; err.hidden = false; return; }
    if (!$('join-consent').checked) { err.textContent = 'Tick the box to share your position with the group.'; err.hidden = false; return; }
    if (st.pending) return;
    var btn = $('join-btn'); btn.disabled = true;
    st.pending = api('POST', '/start', { code: CODE, name: name, deviceId: deviceId() }).then(function (j) {
      st.pending = null; btn.disabled = false;
      if (j.token) { st.token = j.token; store.set(TOKEN_KEY, j.token); }
      handleStatus(j);
    }, function () { st.pending = null; btn.disabled = false; err.textContent = 'No connection. Try again.'; err.hidden = false; });
    // Asking for the position here (a tap) is what iPhone Safari needs to show its permission prompt.
    startGeo();
  }
  function handleStatus(j) {
    var s = j.status;
    if (j.rideName) { $('ride-name').textContent = j.rideName; $('wait-ride').textContent = j.rideName; }
    if (j.ride && j.ride.name) $('ride-name').textContent = j.ride.name;
    if (j.token && j.token !== st.token) { st.token = j.token; store.set(TOKEN_KEY, j.token); }
    if (j._status === 401 || j._status === 403 && !s) { st.token = null; store.set(TOKEN_KEY, null); end('You are no longer in this ride', j.error || 'Open the invite link again to ask the host.'); return; }
    if (!s) { if (j.error) { var e = $('join-err'); e.textContent = j.error; e.hidden = false; show('view-join'); } return; }
    st.status = s;
    if (s === 'PENDING') { show('view-wait'); schedule(4000); return; }
    // Each poll also re-sends the position when it is older than 5 s (a rider standing still stays "seen").
    if (s === 'IN') { enterRide(); render(j); sendPos(false); schedule(document.hidden ? 10000 : 3000); return; }
    if (s === 'DECLINED') return end('The host did not let you in', 'You can ask again in a few minutes from the invite link.');
    if (s === 'REMOVED') return end('You left this ride', 'The host removed you, or you left on another device.');
    if (s === 'NO_RIDE') return end('No live ride has this code', 'Ask the host for a new invite.');
    if (s === 'ENDED') return end('The ride has ended', 'Thanks for riding with the group.');
  }
  function end(title, text) {
    stopAll();
    store.set(TOKEN_KEY, null); st.token = null;
    $('end-title').textContent = title; $('end-text').textContent = text;
    show('view-end');
  }
  function schedule(ms) {
    clearTimeout(st.poll);
    st.poll = setTimeout(tick, ms);
  }
  function tick() {
    if (!st.token) return;
    api('GET', '/state').then(handleStatus, function () { $('loc-pill').textContent = 'No connection, retrying'; schedule(5000); });
  }

  /* ---------- riding ---------- */
  function enterRide() {
    if (!$('view-ride').hidden) return;
    show('view-ride');
    if (!st.map && window.L) {
      st.map = window.L.map('map', { zoomControl: false, attributionControl: true }).setView([20.6, 78.9], 5);
      window.L.tileLayer('https://tile.openstreetmap.org/{z}/{x}/{y}.png', { maxZoom: 19, attribution: 'OpenStreetMap contributors' }).addTo(st.map);
      st.layers.route = window.L.layerGroup().addTo(st.map);
      st.layers.riders = window.L.layerGroup().addTo(st.map);
      st.layers.alerts = window.L.layerGroup().addTo(st.map);
    }
    if (/iPhone|iPad|iPod/.test(navigator.userAgent) || (navigator.platform === 'MacIntel' && navigator.maxTouchPoints > 1)) $('ios-tip').hidden = false;
    if ('Notification' in window && Notification.permission === 'default') $('alerts-btn').hidden = false;
    startGeo();
    keepAwake();
  }
  var COLORS = { LEAD: '#D9822B', SWEEP: '#6C5CE7' };
  function render(j) {
    if (!st.map) return;
    var routeKey = (j.route || '').length;
    if (st.layers.routeKey !== routeKey) {
      st.layers.routeKey = routeKey;
      st.layers.route.clearLayers();
      if (j.route) window.L.polyline(decodePolyline(j.route), { color: '#2B7A8C', weight: 5, opacity: 0.8 }).addTo(st.layers.route);
      if (j.ride && j.ride.destinationLat) window.L.circleMarker([j.ride.destinationLat, j.ride.destinationLng], { radius: 9, color: '#15181C', fillColor: '#FFFFFF', fillOpacity: 1, weight: 3 }).bindTooltip(j.ride.destination || 'Destination').addTo(st.layers.route);
    }
    st.layers.riders.clearLayers();
    var pts = [];
    var list = $('group-list');
    while (list.firstChild) list.removeChild(list.firstChild);
    (j.riders || []).forEach(function (r) {
      var has = r.lat || r.lng;
      if (has) {
        pts.push([r.lat, r.lng]);
        window.L.circleMarker([r.lat, r.lng], { radius: r.me ? 10 : 8, color: '#FFFFFF', weight: 3, fillColor: r.me ? '#3D7BC8' : (COLORS[r.role] || '#1F2328'), fillOpacity: 1 })
          .bindTooltip(r.me ? 'You' : r.name, { permanent: false }).addTo(st.layers.riders);
      }
      var li = document.createElement('li');
      var left = document.createElement('span');
      var nm = document.createElement('b'); nm.textContent = r.me ? r.name + ' (you)' : r.name; left.appendChild(nm);
      if (r.role === 'LEAD' || r.role === 'SWEEP') { var t = document.createElement('span'); t.className = 'tag'; t.textContent = r.role === 'LEAD' ? 'Lead' : 'Sweep'; left.appendChild(t); }
      if (r.isGuest) { var g = document.createElement('span'); g.className = 'tag'; g.textContent = 'Browser'; left.appendChild(g); }
      var right = document.createElement('span'); right.className = 'ago'; right.textContent = ago(r.lastSeen);
      li.appendChild(left); li.appendChild(right); list.appendChild(li);
    });
    if (!st.fitted && pts.length) { st.fitted = true; if (pts.length === 1) st.map.setView(pts[0], 14); else st.map.fitBounds(pts, { padding: [40, 40], maxZoom: 15 }); }
    // Alerts.
    st.layers.alerts.clearLayers();
    var mine = null;
    (j.alerts || []).forEach(function (a) {
      if (a.lat || a.lng) window.L.circleMarker([a.lat, a.lng], { radius: 14, color: '#C0392B', weight: 4, fillColor: '#C0392B', fillOpacity: 0.35 }).bindTooltip((a.mine ? 'Your SOS' : 'SOS: ' + a.name)).addTo(st.layers.alerts);
      if (a.mine) { mine = a; return; }
      if (!st.seen[a.alertId]) { st.seen[a.alertId] = true; alarm(a); }
    });
    st.mySos = mine;
    $('my-sos').hidden = !mine;
  }

  /* ---------- position ---------- */
  function startGeo() {
    if (st.watch !== null || !('geolocation' in navigator)) { if (!('geolocation' in navigator)) setPill('This browser cannot share a position', 'bad'); return; }
    st.watch = navigator.geolocation.watchPosition(function (p) {
      st.myPos = { lat: p.coords.latitude, lng: p.coords.longitude, acc: p.coords.accuracy, speed: p.coords.speed, heading: p.coords.heading };
      setPill('Sharing your position', 'ok');
      sendPos(false);
    }, function (e) {
      setPill(e && e.code === 1 ? 'Location is off: allow it in the browser settings' : 'Waiting for your position', 'bad');
    }, { enableHighAccuracy: true, maximumAge: 5000, timeout: 20000 });
  }
  function setPill(text, kind) { var p = $('loc-pill'); p.textContent = text; p.className = 'pill' + (kind ? ' pill--' + kind : ''); }
  function sendPos(force) {
    if (st.status !== 'IN' || !st.myPos) return;
    var now = Date.now();
    var moved = st.lastSent ? distKm(st.lastSent, st.myPos) * 1000 : 9999;
    if (!force && now - st.lastSentAt < 5000 && moved < 25) return;
    if (!force && now - st.lastSentAt < 2500) return;
    st.lastSentAt = now; st.lastSent = { lat: st.myPos.lat, lng: st.myPos.lng };
    var body = { lat: st.myPos.lat, lng: st.myPos.lng };
    if (typeof st.myPos.speed === 'number' && st.myPos.speed >= 0) body.speedKmh = st.myPos.speed * 3.6;
    if (typeof st.myPos.heading === 'number' && isFinite(st.myPos.heading)) body.heading = st.myPos.heading;
    api('POST', '/position', body).then(function (j) { if (j._status === 401) tick(); }, function () { /* next fix retries */ });
  }
  function keepAwake() {
    if (!('wakeLock' in navigator) || st.wake) return;
    navigator.wakeLock.request('screen').then(function (l) { st.wake = l; l.addEventListener('release', function () { st.wake = null; }); }, function () { /* not allowed now */ });
  }
  document.addEventListener('visibilitychange', function () {
    if (!document.hidden && st.status === 'IN') { keepAwake(); tick(); sendPos(true); }
  });

  /* ---------- alarm (someone else's SOS) ---------- */
  function alarm(a) {
    $('alarm-kind').textContent = a.auto ? 'CRASH ALERT' : 'SOS';
    $('alarm-title').textContent = a.name + ' needs help';
    var t = 'Their position is on the map.';
    if (st.myPos && (a.lat || a.lng)) t = 'About ' + distKm(st.myPos, a).toFixed(1) + ' km from you. Their position is on the map.';
    $('alarm-text').textContent = t;
    $('alarm').hidden = false;
    $('alarm-show').onclick = function () { stopAlarm(); if (st.map && (a.lat || a.lng)) st.map.setView([a.lat, a.lng], 16); };
    $('alarm-ok').focus();
    if (navigator.vibrate) navigator.vibrate([600, 300, 600, 300, 600]);
    beep(true);
    if ('Notification' in window && Notification.permission === 'granted' && document.hidden) {
      try { new Notification((a.auto ? 'Crash alert: ' : 'SOS: ') + a.name + ' needs help', { body: 'Open CoRoute to see where.', tag: a.alertId, requireInteraction: true }); } catch (e) { /* not on this browser */ }
    }
  }
  function beep(on) {
    try {
      if (!on) { if (st.beep) { clearInterval(st.beep); st.beep = null; } return; }
      var Ctx = window.AudioContext || window.webkitAudioContext;
      if (!Ctx) return;
      st.audio = st.audio || new Ctx();
      if (st.audio.state === 'suspended') st.audio.resume();
      var tone = function () {
        [880, 660].forEach(function (f, i) {
          var o = st.audio.createOscillator(), g = st.audio.createGain();
          o.type = 'square'; o.frequency.value = f; g.gain.value = 0.25;
          o.connect(g); g.connect(st.audio.destination);
          var t0 = st.audio.currentTime + i * 0.35; o.start(t0); o.stop(t0 + 0.3);
        });
      };
      tone();
      if (!st.beep) st.beep = setInterval(tone, 1200);
    } catch (e) { /* audio blocked until a tap */ }
  }
  function stopAlarm() { $('alarm').hidden = true; beep(false); if (navigator.vibrate) navigator.vibrate(0); }

  /* ---------- my SOS (hold 3 s) ---------- */
  function sosDown(e) {
    if (e) e.preventDefault();
    if (st.sosTimer) return;
    // Unlocks audio on iPhone (needs a tap) so a later alarm can sound.
    beep(false); try { var C = window.AudioContext || window.webkitAudioContext; if (C && !st.audio) st.audio = new C(); if (st.audio && st.audio.state === 'suspended') st.audio.resume(); } catch (x) { /* ignore */ }
    $('sos-btn').classList.add('is-holding');
    st.sosTimer = setTimeout(function () { st.sosTimer = null; $('sos-btn').classList.remove('is-holding'); raiseSos(); }, 3000);
  }
  function sosUp() {
    if (!st.sosTimer) return;
    clearTimeout(st.sosTimer); st.sosTimer = null;
    $('sos-btn').classList.remove('is-holding');
    toast('Hold for 3 seconds to send SOS');
  }
  function raiseSos() {
    if (navigator.vibrate) navigator.vibrate(400);
    var cid = store.get('cr.guest.sos.' + CODE) || ('gw' + Date.now().toString(36) + Math.random().toString(36).slice(2, 10));
    store.set('cr.guest.sos.' + CODE, cid);
    var tries = 0;
    var body = { clientId: cid };
    if (st.myPos) { body.lat = st.myPos.lat; body.lng = st.myPos.lng; body.accuracyM = st.myPos.acc; }
    $('my-sos').hidden = false;
    (function send() {
      tries++;
      api('POST', '/sos', body).then(function (j) {
        if (j._status === 201) { toast('SOS sent to your group'); tick(); return; }
        if (tries < 10) setTimeout(send, 3000); else toast(j.error || 'SOS not sent. Call 112.');
      }, function () { if (tries < 10) setTimeout(send, 3000); else toast('No connection. Call 112.'); });
    })();
  }
  function cancelSos() {
    var a = st.mySos;
    if (!a) { $('my-sos').hidden = true; return; }
    var b = $('my-sos-cancel'); b.disabled = true;
    api('POST', '/sos/' + encodeURIComponent(a.alertId) + '/cancel', {}).then(function (j) {
      b.disabled = false;
      if (j.ok) { store.set('cr.guest.sos.' + CODE, null); $('my-sos').hidden = true; toast('SOS cancelled. Your group sees you are OK.'); tick(); } else toast(j.error || 'Could not cancel.');
    }, function () { b.disabled = false; toast('No connection. Try again.'); });
  }

  function stopAll() {
    clearTimeout(st.poll);
    if (st.watch !== null && navigator.geolocation) navigator.geolocation.clearWatch(st.watch);
    st.watch = null;
    if (st.wake) { try { st.wake.release(); } catch (e) { /* gone */ } st.wake = null; }
    beep(false);
  }

  /* ---------- wire up ---------- */
  function init() {
    if (!CODE) { end('This link is not right', 'Open the invite link again.'); return; }
    $('join-code').textContent = CODE;
    $('join-form').addEventListener('submit', startJoin);
    $('wait-cancel').addEventListener('click', function () { api('POST', '/leave', {}).then(function () { end('Request cancelled', 'You can ask again from the invite link.'); }); });
    $('group-btn').addEventListener('click', function () {
      var p = $('group-panel'); p.hidden = !p.hidden; this.setAttribute('aria-expanded', String(!p.hidden));
    });
    $('leave-btn').addEventListener('click', function () {
      if (!window.confirm('Leave the ride? The group stops seeing you.')) return;
      this.disabled = true;
      api('POST', '/leave', {}).then(function () { end('You left the ride', 'Thanks for riding with the group.'); });
    });
    $('alarm-ok').addEventListener('click', stopAlarm);
    $('alerts-btn').addEventListener('click', function () {
      var btn = this;
      Notification.requestPermission().then(function (p) { btn.hidden = true; toast(p === 'granted' ? 'Alerts are on while this page is open' : 'Alerts stay on this page only'); });
    });
    var sos = $('sos-btn');
    sos.addEventListener('pointerdown', sosDown);
    ['pointerup', 'pointercancel', 'pointerleave'].forEach(function (ev) { sos.addEventListener(ev, sosUp); });
    sos.addEventListener('contextmenu', function (e) { e.preventDefault(); });
    sos.addEventListener('keydown', function (e) { if ((e.key === 'Enter' || e.key === ' ') && !e.repeat) sosDown(e); });
    sos.addEventListener('keyup', function (e) { if (e.key === 'Enter' || e.key === ' ') sosUp(); });
    $('my-sos-cancel').addEventListener('click', cancelSos);
    if (st.token) { show('view-wait'); tick(); } else show('view-join');
  }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', init); else init();
})();
