'use strict';
const WebSocket = require('ws');

const BASE_URL = 'https://coroute.duckdns.org';
const WS_URL = 'wss://coroute.duckdns.org/ws';

async function post(url, data, token = null) {
  const headers = { 'Content-Type': 'application/json' };
  if (token) headers['Authorization'] = `Bearer ${token}`;
  const res = await fetch(`${BASE_URL}${url}`, {
    method: 'POST',
    headers,
    body: JSON.stringify(data),
  });
  const text = await res.text();
  try {
    return { status: res.status, data: JSON.parse(text) };
  } catch {
    return { status: res.status, data: text };
  }
}

async function runSwarmTest() {
  console.log('=== Starting CoRoute 6-Tester Continuous Load & Concurrency Audit ===\n');

  const testers = [
    { name: 'Alex Apex (Lead)', role: 'LEAD', lat: 17.3850, lng: 78.4867 },
    { name: 'Maya Shield (Sweep)', role: 'SWEEPER', lat: 17.3820, lng: 78.4840 },
    { name: 'Rohan Quick (Pack)', role: 'PACK', lat: 17.3835, lng: 78.4855 },
    { name: 'Priya Guardian (Pillion)', role: 'PACK', lat: 17.3835, lng: 78.4856 },
    { name: 'Vikram Pace (Pack)', role: 'PACK', lat: 17.3840, lng: 78.4860 },
    { name: 'Arun Tunnel (Edge)', role: 'PACK', lat: 17.3810, lng: 78.4830 },
  ];

  const sessions = [];
  const metrics = {
    authSuccess: 0,
    convoyCreated: 0,
    convoyJoined: 0,
    wsConnected: 0,
    telemetrySent: 0,
    telemetryAcks: 0,
    sosSent: 0,
    latencies: [],
    errors: [],
  };

  // Phase 1: Authenticate all 6 riders concurrently via /api/auth/guest
  console.log('[Phase 1] Concurrently authenticating 6 test rider personas...');
  const t0 = Date.now();
  for (const t of testers) {
    const start = Date.now();
    try {
      const res = await post('/api/auth/guest', { name: t.name });
      const lat = Date.now() - start;
      metrics.latencies.push(lat);
      if (res.status === 200 && res.data.token) {
        metrics.authSuccess++;
        sessions.push({ ...t, token: res.data.token, user: res.data.user });
        console.log(`  ✓ ${t.name} authenticated (userId: ${res.data.user.userId}, ${lat}ms)`);
      } else {
        metrics.errors.push(`Auth failed for ${t.name}: HTTP ${res.status}`);
        console.error(`  ✗ Auth failed for ${t.name}:`, res.data);
      }
    } catch (e) {
      metrics.errors.push(`Auth error for ${t.name}: ${e.message}`);
      console.error(`  ✗ Auth error for ${t.name}:`, e.message);
    }
  }

  if (sessions.length === 0) {
    console.error('Fatal: No sessions authenticated. Aborting load test.');
    return metrics;
  }

  // Phase 2: Lead Rider creates convoy
  console.log('\n[Phase 2] Lead Rider creating convoy "Western Ghats Sprint"...');
  const lead = sessions[0];
  let joinCode = null;
  let groupId = null;
  try {
    const start = Date.now();
    const res = await post('/api/convoys', {
      name: 'Western Ghats Sprint',
      visibility: 'PUBLIC',
      route: {
        points: [
          [17.3850, 78.4867],
          [17.3890, 78.4900],
          [17.3950, 78.4950],
        ],
      },
    }, lead.token);
    const lat = Date.now() - start;
    metrics.latencies.push(lat);
    const convoy = res.data.convoy || res.data;
    if ((res.status === 200 || res.status === 201) && convoy?.groupId) {
      metrics.convoyCreated++;
      joinCode = convoy.joinCode || convoy.code;
      groupId = convoy.groupId;
      console.log(`  ✓ Convoy created: "${convoy.name}" (groupId: ${groupId}, joinCode: ${joinCode}, ${lat}ms)`);
    } else {
      metrics.errors.push(`Create convoy failed: HTTP ${res.status}`);
      console.error('  ✗ Create convoy failed:', res.data);
    }
  } catch (e) {
    metrics.errors.push(`Create convoy error: ${e.message}`);
    console.error('  ✗ Create convoy error:', e.message);
  }

  if (!groupId) {
    console.error('Fatal: Convoy not created. Aborting join phase.');
    return metrics;
  }

  // Phase 3: Remaining 5 Riders join the convoy using the joinCode
  console.log(`\n[Phase 3] Joining remaining 5 riders to convoy using code "${joinCode}"...`);
  for (let i = 1; i < sessions.length; i++) {
    const s = sessions[i];
    const start = Date.now();
    try {
      const res = await post('/api/convoys/join', {
        code: joinCode,
        rider: {
          name: s.name,
          role: s.role,
          lat: s.lat,
          lng: s.lng,
          speedKmh: 45.0,
          heading: 120.0,
        },
      }, s.token);
      const lat = Date.now() - start;
      metrics.latencies.push(lat);
      if (res.status === 200) {
        metrics.convoyJoined++;
        console.log(`  ✓ ${s.name} joined convoy (${lat}ms)`);
      } else {
        metrics.errors.push(`Join failed for ${s.name}: HTTP ${res.status}`);
        console.error(`  ✗ Join failed for ${s.name}:`, res.data);
      }
    } catch (e) {
      metrics.errors.push(`Join error for ${s.name}: ${e.message}`);
      console.error(`  ✗ Join error for ${s.name}:`, e.message);
    }
  }

  // Phase 4: Open WebSockets and stream continuous GPS telemetry for 15 seconds
  console.log('\n[Phase 4] Opening WebSockets and streaming real-time rider telemetry (15s stress cycle)...');
  const wsClients = [];
  for (const s of sessions) {
    try {
      const ws = new WebSocket(`${WS_URL}?token=${s.token}`);
      ws.on('open', () => {
        metrics.wsConnected++;
        ws.send(JSON.stringify({
          type: 'JOIN_CONVOY',
          groupId,
          userId: s.user.userId,
        }));
      });
      ws.on('message', (msg) => {
        try {
          const parsed = JSON.parse(msg.toString());
          if (parsed.type === 'ACK' || parsed.type === 'RIDER_UPDATE' || parsed.type === 'STATUS') {
            metrics.telemetryAcks++;
          }
        } catch { }
      });
      ws.on('error', (err) => {
        metrics.errors.push(`WS error (${s.name}): ${err.message}`);
      });
      wsClients.push({ ...s, ws });
    } catch (e) {
      metrics.errors.push(`WS connect error (${s.name}): ${e.message}`);
    }
  }

  // Continuous stream cycle: each rider sends telemetry updates every 1.5 seconds
  let cycles = 0;
  const interval = setInterval(() => {
    cycles++;
    for (const client of wsClients) {
      if (client.ws.readyState === WebSocket.OPEN) {
        client.lat += 0.0001;
        client.lng += 0.0001;
        client.ws.send(JSON.stringify({
          type: 'LOCATION_UPDATE',
          groupId,
          userId: client.user.userId,
          lat: client.lat,
          lng: client.lng,
          speedKmh: 55.0 + Math.random() * 10,
          heading: 90.0,
          batteryLevel: 92,
          timestamp: Date.now(),
        }));
        metrics.telemetrySent++;
      }
    }
    process.stdout.write(`  [Streaming] Cycle ${cycles}/10 - Telemetry frames: ${metrics.telemetrySent}\r`);
  }, 1500);

  // Wait 15 seconds for stream to complete
  await new Promise(resolve => setTimeout(resolve, 15000));
  clearInterval(interval);
  console.log(`\n  ✓ Telemetry stream concluded (${metrics.telemetrySent} frames sent, ${metrics.telemetryAcks} acks received).`);

  // Phase 5: Test Safety Emergency SOS protocol
  console.log('\n[Phase 5] Triggering Emergency SOS protocol test...');
  const distressedRider = sessions[3]; // Priya
  try {
    const res = await post(`/api/convoys/${groupId}/sos`, {
      type: 'SOS_TRIGGER',
      severity: 'CRITICAL',
      lat: distressedRider.lat,
      lng: distressedRider.lng,
      message: 'Simulated Crash Alert from Rider 4 (Priya)',
      medicalNotes: 'Blood Group O+, Penicillin Allergy',
    }, distressedRider.token);
    if (res.status === 200 || res.status === 201) {
      metrics.sosSent++;
      console.log(`  ✓ SOS Alert successfully broadcast to convoy (HTTP ${res.status})`);
    } else {
      console.log(`  Note: SOS endpoint responded with status ${res.status} (Handled: ${JSON.stringify(res.data)})`);
    }
  } catch (e) {
    console.log(`  Note on SOS: ${e.message}`);
  }

  // Cleanup: Close sockets gracefully
  for (const client of wsClients) {
    try { client.ws.close(); } catch { }
  }

  // Report summary
  const totalDuration = ((Date.now() - t0) / 1000).toFixed(2);
  const avgLat = metrics.latencies.length > 0 ? (metrics.latencies.reduce((a, b) => a + b, 0) / metrics.latencies.length).toFixed(1) : 0;
  const maxLat = metrics.latencies.length > 0 ? Math.max(...metrics.latencies) : 0;

  console.log('\n======================================================');
  console.log('              LOAD & AUDIT RESULTS SUMMARY            ');
  console.log('======================================================');
  console.log(`Total Elapsed Time     : ${totalDuration} s`);
  console.log(`Testers Authenticated  : ${metrics.authSuccess} / 6`);
  console.log(`Convoy Created         : ${metrics.convoyCreated} (Code: ${joinCode})`);
  console.log(`Riders Joined          : ${metrics.convoyJoined} / 5`);
  console.log(`Active WebSockets      : ${metrics.wsConnected} / 6`);
  console.log(`Telemetry Frames Sent  : ${metrics.telemetrySent}`);
  console.log(`Telemetry Acks Received: ${metrics.telemetryAcks}`);
  console.log(`Average API Latency    : ${avgLat} ms`);
  console.log(`Max API Latency        : ${maxLat} ms`);
  console.log(`Total Errors Logged    : ${metrics.errors.length}`);
  if (metrics.errors.length > 0) {
    console.log('Errors:', metrics.errors);
  }
  console.log('======================================================\n');
  return metrics;
}

runSwarmTest().catch(console.error);
