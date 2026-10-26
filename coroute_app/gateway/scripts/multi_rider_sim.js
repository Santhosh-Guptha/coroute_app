'use strict';

const jwt = require('jsonwebtoken');
const { WebSocket } = require('ws');
const https = require('https');

const JWT_SECRET = '0oFOo4EZMkqdTYW2CcdM3ZUqZUv2NqY8IMCH9UqOJki23ENaBnmFZ/c1CbUbYU65';
const BASE_HOST = 'coroute.duckdns.org';
const INVITE_CODE = '612495';

function makeToken(userId, name, email) {
  return jwt.sign(
    { sub: userId, name, email, role: 'RIDER', pv: 0 },
    JWT_SECRET,
    { expiresIn: '7d', issuer: 'coroute-gateway' }
  );
}

const rider2 = {
  name: 'Shadow-Sweeper',
  email: 'sweeper@devmonks.space',
  password: 'CoRoutePassword2026!',
  token: null,
  role: 'SWEEPER',
  lat: 37.4215,
  lng: -122.0835,
  vehicleType: 'Motorcycle',
  vehicleNo: 'KA-01-SWEEP',
  phone: '+15550202',
};

const rider3 = {
  name: 'Ghost-Wingman',
  email: 'wingman@devmonks.space',
  password: 'CoRoutePassword2026!',
  token: null,
  role: 'PACK',
  lat: 37.4225,
  lng: -122.0845,
  vehicleType: 'Motorcycle',
  vehicleNo: 'KA-01-GHOST',
  phone: '+15550303',
};

async function getOrRegisterRider(riderData) {
  try {
    const regRes = await apiPost('/auth/register', null, {
      name: riderData.name,
      email: riderData.email,
      password: riderData.password,
      phone: riderData.phone,
      vehicleType: riderData.vehicleType,
      vehicleNo: riderData.vehicleNo,
      emergencyContact: '+15559999',
      emergencyContactName: 'Fleet HQ',
    });
    console.log(`✓ Registered rider: ${riderData.name} (${regRes.user.userId})`);
    return regRes.token;
  } catch (err) {
    if (err.message.includes('already registered') || err.message.includes('CALLSIGN_TAKEN') || err.message.includes('409')) {
      const loginRes = await apiPost('/auth/login', null, {
        identifier: riderData.email,
        password: riderData.password,
      });
      console.log(`✓ Logged in existing rider: ${riderData.name} (${loginRes.user.userId})`);
      return loginRes.token;
    }
    throw err;
  }
}

function apiPost(path, token, body) {
  return new Promise((resolve, reject) => {
    const data = JSON.stringify(body);
    const headers = {
      'Content-Type': 'application/json',
      'Content-Length': Buffer.byteLength(data),
      'Accept': 'application/json',
    };
    if (token) headers['Authorization'] = `Bearer ${token}`;
    const req = https.request(
      {
        hostname: BASE_HOST,
        port: 443,
        path: `/api${path}`,
        method: 'POST',
        headers,
      },
      (res) => {
        let resp = '';
        res.on('data', (c) => (resp += c));
        res.on('end', () => {
          try {
            const parsed = JSON.parse(resp);
            if (res.statusCode >= 200 && res.statusCode < 300) {
              resolve(parsed);
            } else {
              reject(new Error(`API Error ${res.statusCode}: ${resp}`));
            }
          } catch (e) {
            reject(new Error(`Failed to parse: ${resp}`));
          }
        });
      }
    );
    req.on('error', reject);
    req.write(data);
    req.end();
  });
}

function connectWs(token, name) {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(`wss://${BASE_HOST}/ws?token=${encodeURIComponent(token)}`);
    ws.on('open', () => {
      console.log(`[WS] ${name} connected to wss://${BASE_HOST}/ws`);
    });
    ws.on('error', (err) => {
      console.error(`[WS ERROR] ${name}:`, err.message);
      reject(err);
    });
    ws.on('message', (data) => {
      try {
        const str = Buffer.isBuffer(data) ? data.toString('utf8') : String(data);
        const msg = JSON.parse(str);
        if (msg.type === 'HELLO') {
          console.log(`[WS] ${name} received HELLO`);
          resolve({ ws, hello: msg });
        }
      } catch (_) {}
    });
  });
}

async function runSimulation() {
  console.log('=== CoRoute Multi-Rider Live Trip Simulation ===');
  console.log(`Target Convoy Invite Code: ${INVITE_CODE}`);

  console.log('\n--- Step 0: Ensuring Riders are Authenticated ---');
  rider2.token = await getOrRegisterRider(rider2);
  rider3.token = await getOrRegisterRider(rider3);

  let groupId = null;

  // Step 1: Join Convoy via REST API
  console.log('\n--- Step 1: Riders Joining Convoy via REST API ---');
  try {
    const joinRes2 = await apiPost('/convoys/join', rider2.token, {
      code: INVITE_CODE,
      rider: {
        lat: rider2.lat,
        lng: rider2.lng,
        vehicleType: rider2.vehicleType,
        vehicleNo: rider2.vehicleNo,
        phone: rider2.phone,
        batteryLevel: 92,
        isCharging: false,
      },
    });
    groupId = joinRes2.groupId;
    console.log(`✓ Rider 2 (${rider2.name}) successfully joined Convoy ${groupId} as ${joinRes2.riders?.[rider2.userId]?.role || 'PACK'}`);

    const joinRes3 = await apiPost('/convoys/join', rider3.token, {
      code: INVITE_CODE,
      rider: {
        lat: rider3.lat,
        lng: rider3.lng,
        vehicleType: rider3.vehicleType,
        vehicleNo: rider3.vehicleNo,
        phone: rider3.phone,
        batteryLevel: 85,
        isCharging: false,
      },
    });
    console.log(`✓ Rider 3 (${rider3.name}) successfully joined Convoy ${groupId}`);
    console.log(`  Convoy members: ${Object.keys(joinRes3.riders || {}).length} riders connected.`);
  } catch (err) {
    console.error('Join error:', err.message);
    process.exit(1);
  }

  // Step 2: Establish WebSockets
  console.log('\n--- Step 2: Opening Live Realtime WebSockets ---');
  const client2 = await connectWs(rider2.token, rider2.name);
  const client3 = await connectWs(rider3.token, rider3.name);

  // Subscribe both to group
  client2.ws.send(JSON.stringify({ type: 'JOIN', groupId, caps: ['net1'] }));
  client3.ws.send(JSON.stringify({ type: 'JOIN', groupId, caps: ['net1'] }));
  console.log(`✓ Both riders sent JOIN frame to room ${groupId}`);

  client2.ws.on('message', (d) => {
    try {
      const str = Buffer.isBuffer(d) ? d.toString('utf8') : String(d);
      const msg = JSON.parse(str);
      if (['ALERT', 'ROAD_HAZARD', 'MIC_STATUS', 'REGROUP_SET', 'RIDER_UPDATE', 'SNAPSHOT'].includes(msg.type)) {
        console.log(`[EVENT on Rider 2] ${msg.type}:`, JSON.stringify(msg).slice(0, 140));
      }
    } catch (_) {}
  });

  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
  await sleep(2000);

  // Scenario A: Set Sweeper Role & Telemetry (Roster Sync)
  console.log('\n--- Scenario A: Assign Roles & Synchronize Echelon Telemetry ---');
  client2.ws.send(JSON.stringify({
    type: 'ROLE_SET',
    role: 'SWEEPER',
    clientId: `role_${Date.now()}`,
  }));
  client2.ws.send(JSON.stringify({
    type: 'STATUS',
    lat: 37.4215,
    lng: -122.0835,
    speedKmh: 45,
    battery: 92,
    charging: false,
    moving: true,
  }));
  client3.ws.send(JSON.stringify({
    type: 'STATUS',
    lat: 37.4225,
    lng: -122.0845,
    speedKmh: 48,
    battery: 85,
    charging: false,
    moving: true,
  }));
  console.log('✓ Echelon status updates dispatched: Sweeper (45 km/h) & Wingman (48 km/h)');
  await sleep(4000);

  // Scenario B: Road Hazard Broadcast (POWDER_GRAVEL)
  console.log('\n--- Scenario B: Broadcast Road Hazard (POWDER_GRAVEL) ---');
  client2.ws.send(JSON.stringify({
    type: 'ROAD_HAZARD',
    hazardType: 'POWDER_GRAVEL',
    severity: 'MODERATE',
    lat: 37.4230,
    lng: -122.0850,
    heading: 270,
    speedKmh: 45,
    note: 'Loose powder gravel on right curve',
  }));
  console.log('✓ Road Hazard POWDER_GRAVEL frame broadcast by Rider 2');
  await sleep(4000);

  // Scenario C: Tunnel Dead Reckoning Mode
  console.log('\n--- Scenario C: Dead Reckoning Coasting in Tunnel ---');
  client3.ws.send(JSON.stringify({
    type: 'STATUS',
    lat: 37.4240,
    lng: -122.0860,
    speedKmh: 55,
    tunnel: true,
    isCoasting: true,
    trackingConfidence: 'deadReckoningCoasting',
    battery: 84,
    moving: true,
  }));
  console.log('✓ Tunnel dead reckoning coasting status dispatched by Rider 3');
  await sleep(4000);

  // Scenario D: PTT Intercom Active Speaker
  console.log('\n--- Scenario D: PTT Voice Intercom Active Speaker Indication ---');
  client2.ws.send(JSON.stringify({
    type: 'MIC_STATE',
    isSpeaking: true,
    micMuted: false,
  }));
  console.log('✓ Rider 2 keyed microphone (isSpeaking: true, micMuted: false)');
  await sleep(3000);
  client2.ws.send(JSON.stringify({
    type: 'MIC_STATE',
    isSpeaking: false,
    micMuted: false,
  }));
  console.log('✓ Rider 2 released microphone (isSpeaking: false)');
  await sleep(3000);

  // Scenario E: Dynamic Regroup Waypoint Beacon
  console.log('\n--- Scenario E: Dynamic Regroup Waypoint Beacon ---');
  client2.ws.send(JSON.stringify({
    type: 'REGROUP_SET',
    lat: 37.4260,
    lng: -122.0880,
    name: 'Charleston Highway Rest Stop',
    clientId: `regroup_${Date.now()}`,
  }));
  console.log('✓ Regroup waypoint beacon broadcast: "Charleston Highway Rest Stop"');
  await sleep(4000);

  // Scenario F: Wearable Airbag 6.0G Crash Escalation
  console.log('\n--- Scenario F: Wearable Airbag 6.0G Crash Escalation ---');
  client3.ws.send(JSON.stringify({
    type: 'SOS',
    severity: 'CRITICAL',
    impactG: 6.2,
    source: 'wearable_airbag',
    lat: 37.4245,
    lng: -122.0865,
    clientId: `sos_${Date.now()}`,
    note: 'Airbag deployed - High-G deceleration impact',
  }));
  console.log('✓ Wearable Airbag 6.2G Crash SOS emergency alert broadcast by Rider 3!');
  await sleep(5000);

  console.log('\n=== All Real-World Convoy Scenarios Successfully Executed! ===');
  client2.ws.close();
  client3.ws.close();
}

runSimulation().catch((e) => {
  console.error('Fatal Simulation Error:', e);
  process.exit(1);
});
