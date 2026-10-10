/* Private observer page: no analytics, service-worker cache or location access. */
(() => {
  'use strict';
  const el = (id) => document.getElementById(id);
  const fragment = new URLSearchParams(location.hash.slice(1));
  let secret = fragment.get('token'), ticket = fragment.get('ticket');
  const readStored = (key) => { try { return localStorage.getItem(key); } catch { return null; } };
  const store = (key, value) => { try { if (value == null) localStorage.removeItem(key); else localStorage.setItem(key, value); } catch { /* optional resume */ } };
  history.replaceState(null, '', '/watch');
  let sessionId = secret || ticket ? null : readStored('guardianSession'), timer = null, expiryTimer = null, running = false, stopped = false, failures = 0, pageActive = true;
  const states = { WAITING_FOR_START: 'The ride has not started.', RIDE_ENDED: 'The ride has ended.',
    RIDING: 'Riding', STOPPED: 'Stopped', PAUSED: 'Ride paused', LOCATION_UNAVAILABLE: 'Location updates are unavailable.',
    NO_ACTIVE_ALERT: 'No active alert reported.', EMERGENCY: 'Help has been requested.', UNAVAILABLE: 'Status unavailable.' };
  function clear() {
    el('ride-title').textContent = 'Personal ride'; el('ride-status').textContent = '';
    el('freshness').textContent = ''; el('incident').textContent = ''; el('expiry').textContent = '';
    el('riders').replaceChildren(); el('timeline').replaceChildren();
    el('location').hidden = true; el('location').removeAttribute('href');
  }
  let pushConfig = null, subscriptionId = null;
  function expired() {
    if (readStored('guardianSession') === sessionId) store('guardianSession', null);
    el('push-controls').hidden = true;
    stopped = true; clearTimeout(timer); clearTimeout(expiryTimer); clear();
    el('connection').textContent = 'Access ended. Reopen a valid shared link to continue.';
    el('retry').hidden = true; document.querySelector('.guardian__card').dataset.tone = 'unknown';
  }
  async function request(url, options = {}) {
    const controller = new AbortController(); const timeout = setTimeout(() => controller.abort(), 10000);
    try {
      const res = await fetch(url, { ...options, credentials: 'same-origin', cache: 'no-store', signal: controller.signal });
      if (!res.ok) { const error = new Error('Request failed'); error.status = res.status; error.code = (await res.json().catch(() => ({}))).code; throw error; }
      return await res.json();
    } finally { clearTimeout(timeout); }
  }
  function render(data) {
    clear();
    el('ride-title').textContent = data.name ? `${data.name}'s ride` : 'Personal ride';
    el('ride-status').textContent = states[data.status] || states.UNAVAILABLE;
    el('connection').textContent = 'Connected · personal access';
    if (data.observedAt) el('freshness').textContent = `Location reported ${new Date(data.observedAt).toLocaleString()}`;
    if (data.scope === 'GROUP') {
      el('ride-title').textContent = 'Shared group ride';
      el('ride-status').textContent = data.emergency ? 'Help has been requested.' : (states[data.status] || 'Group update');
      el('connection').textContent = 'Connected · consenting riders only';
      if (data.summary) el('freshness').textContent = `${data.summary.riding} riding · ${data.summary.stopped} stopped · ${data.summary.unavailable} without current location`;
      for (const rider of data.riders || []) {
        const row = document.createElement('p');
        row.textContent = `${rider.name || 'Rider'}: ${states[rider.status] || states.UNAVAILABLE}`;
        if (rider.observedAt) row.append(` · reported ${new Date(rider.observedAt).toLocaleString()}`);
        const position = rider.alerts?.[0]?.position || rider.position;
        if (position) {
          const link = document.createElement('a'); link.textContent = ' View last reported location';
          link.rel = 'noreferrer noopener'; link.target = '_blank';
          link.href = `https://www.openstreetmap.org/?mlat=${encodeURIComponent(position.lat)}&mlon=${encodeURIComponent(position.lng)}`;
          row.append(link);
        }
        el('riders').append(row);
      }
    }
    for (const event of data.timeline || []) {
      const item = document.createElement('li');
      item.textContent = `${new Date(event.at).toLocaleString()} · ${event.label}${event.open ? ' (ongoing)' : ''}`;
      el('timeline').append(item);
    }
    const alert = data.alerts?.[0];
    if (alert) el('incident').textContent = alert.type === 'POSSIBLE_ACCIDENT'
      ? 'A possible accident was reported. This is not confirmation of injury.' : 'An active request for help was reported.';
    const position = alert?.position || data.position;
    if (position) {
      el('location').href = `https://www.openstreetmap.org/?mlat=${encodeURIComponent(position.lat)}&mlon=${encodeURIComponent(position.lng)}#map=16/${encodeURIComponent(position.lat)}/${encodeURIComponent(position.lng)}`;
      el('location').hidden = false;
      if (position.stale) el('freshness').textContent += ' · Last known location';
    }
    document.querySelector('.guardian__card').dataset.tone = data.emergency ? 'critical' : data.status === 'LOCATION_UNAVAILABLE' ? 'unknown' : 'normal';
    el('expiry').textContent = `This viewing session ends ${new Date(data.expiresAt).toLocaleString()}.`;
    clearTimeout(expiryTimer); expiryTimer = setTimeout(expired, Math.max(0, data.expiresAt - data.serverTime));
  }
  async function update() {
    if (running || stopped || document.hidden || !pageActive) return;
    running = true; clearTimeout(timer); el('retry').hidden = true;
    try {
      if (!sessionId) {
        if (!secret && !ticket) { expired(); return; }
        const session = await request(ticket ? '/api/guardian/ticket' : '/api/guardian/session', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(ticket ? { ticket } : { token: secret, pin: el('pin').value || undefined }) });
        sessionId = session.sessionId; secret = null; ticket = null;
        store('guardianSession', sessionId); el('pin').value = ''; el('pin-box').hidden = true;
      }
      const data = await request(`/api/guardian/sessions/${sessionId}/snapshot`);
      if (!stopped && !document.hidden && pageActive) render(data); failures = 0;
      if (!pushConfig) pushConfig = await request('/api/guardian/capabilities').catch(() => ({ push: false }));
      el('push-controls').hidden = stopped || !pushConfig.push || !('serviceWorker' in navigator) || !('PushManager' in window) || !('Notification' in window);
    } catch (error) {
      if (error.code === 'GUARDIAN_PAUSED') { clear(); el('connection').textContent = 'The rider has paused this link.'; failures = 1; }
      else if (error.code === 'GUARDIAN_PIN_REQUIRED') {
        el('pin-box').hidden = false; el('retry').hidden = false;
        el('connection').textContent = 'Enter the PIN shared separately by the rider.';
        failures = 3;
      } else if ([401, 403, 404, 410].includes(error.status)) expired();
      else {
        clear(); // No cached location is presented as a successful new update.
        el('connection').textContent = 'Updates unavailable. Check your connection and try again.';
        el('retry').hidden = false; failures = Math.min(3, failures + 1);
      }
    } finally {
      running = false;
      if (!stopped && !document.hidden && pageActive && el('pin-box').hidden) timer = setTimeout(update, 15000 * 2 ** failures);
    }
  }
  el('enable-alerts').addEventListener('click', async () => {
    if (!sessionId || !pushConfig?.push) return;
    el('enable-alerts').disabled = true;
    try {
      if (await Notification.requestPermission() !== 'granted') throw new Error('Permission was not granted. You can continue using the live page.');
      const registration = await navigator.serviceWorker.register('/watch-sw.js', { scope: '/watch' });
      await navigator.serviceWorker.ready;
      const raw = atob(pushConfig.publicKey.replace(/-/g, '+').replace(/_/g, '/'));
      const applicationServerKey = Uint8Array.from(raw, (c) => c.charCodeAt(0));
      const subscription = await registration.pushManager.getSubscription() || await registration.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey });
      const result = await request(`/api/guardian/sessions/${sessionId}/subscription`, { method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ subscription: subscription.toJSON(), preferences: { emergencies: el('push-emergencies').checked, trip: el('push-trip').checked } }) });
      subscriptionId = result.subscriptionId;
      el('push-status').textContent = 'Alerts enabled for this link. Delivery is not guaranteed.';
      el('disable-alerts').hidden = false;
    } catch (e) { el('push-status').textContent = e.message || 'Could not enable alerts. Try your system browser.'; }
    finally { el('enable-alerts').disabled = false; }
  });
  el('disable-alerts').addEventListener('click', async () => {
    try {
      await request(`/api/guardian/sessions/${sessionId}/subscription/${subscriptionId}`, { method: 'DELETE' });
      el('push-status').textContent = 'Alerts disabled for this link. A new link is needed to enable them again.';
      el('disable-alerts').hidden = true;
    } catch { el('push-status').textContent = 'Could not disable alerts. Try again or ask the rider to revoke the link.'; }
  });
  window.addEventListener('pagehide', () => { pageActive = false; clearTimeout(timer); clear(); });
  window.addEventListener('pageshow', () => { pageActive = true; if (!stopped) update(); });
  el('retry').addEventListener('click', update);
  document.addEventListener('visibilitychange', () => { clearTimeout(timer); if (!document.hidden) update(); else clear(); });
  window.addEventListener('online', update);
  update();
})();
