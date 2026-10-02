const express = require('express');
const http = require('http');
const WebSocket = require('ws');
const cors = require('cors');
const helmet = require('helmet');
const os = require('os');

const app = express();
const server = http.createServer(app);
const wss = new WebSocket.Server({ server, path: '/ws/telemetry' });

const PORT = process.env.PORT || 3000;
const SODA_URL = process.env.SODA_URL || 'https://gfe473165e66472-coroutedb.adb.ap-hyderabad-1.oraclecloudapps.com/ords/admin/soda/latest';
const ORACLE_AUTH = process.env.ORACLE_AUTH || 'Basic QURNSU46RGV2TW9ua3MjT3JhY2xlMjZhaSE=';

app.use(cors());
app.use(helmet({ contentSecurityPolicy: false }));
app.use(express.json());

// In-memory active convoy rooms for low-latency WebSocket broadcast
const convoyRooms = new Map(); // convoyId -> Map(riderId -> ws)

// 1. Root Information
app.get('/', (req, res) => {
  res.json({
    service: 'CoRoute Real-Time Gateway & Oracle 26ai Sync',
    organization: 'devmonks.space',
    version: '2.4.0',
    status: 'ONLINE',
    serverTime: new Date().toISOString(),
    endpoints: {
      health: '/health',
      oracleHealth: '/api/oracle/health',
      trips: '/api/oracle/trips',
      convoys: '/api/oracle/convoys',
      websocket: 'ws://' + (req.headers.host || '152.67.181.198') + '/ws/telemetry'
    }
  });
});

// 2. Health & System Metrics
app.get('/health', async (req, res) => {
  const totalMem = os.totalmem();
  const freeMem = os.freemem();
  const uptimeSec = os.uptime();

  // Test Oracle 26ai connectivity
  let oracleStatus = 'UNKNOWN';
  try {
    const response = await fetch(SODA_URL, {
      headers: { 'Authorization': ORACLE_AUTH, 'Accept': 'application/json' },
      signal: AbortSignal.timeout(4000)
    });
    oracleStatus = response.status === 200 ? 'CONNECTED' : `HTTP_${response.status}`;
  } catch (err) {
    oracleStatus = `ERROR: ${err.message}`;
  }

  res.json({
    status: 'HEALTHY',
    hostname: os.hostname(),
    platform: os.platform(),
    arch: os.arch(),
    nodeVersion: process.version,
    uptimeSeconds: Math.floor(uptimeSec),
    memory: {
      totalMb: Math.round(totalMem / (1024 * 1024)),
      freeMb: Math.round(freeMem / (1024 * 1024)),
      usedMb: Math.round((totalMem - freeMem) / (1024 * 1024)),
      usagePercent: Math.round(((totalMem - freeMem) / totalMem) * 100)
    },
    oracle26ai: {
      status: oracleStatus,
      endpoint: SODA_URL,
      region: 'ap-hyderabad-1'
    },
    telemetryHub: {
      activeRooms: convoyRooms.size,
      connectedClients: wss.clients.size
    }
  });
});

// 3. Oracle 26ai SODA Proxy - Trips
app.get('/api/oracle/trips', async (req, res) => {
  try {
    const response = await fetch(`${SODA_URL}/trips`, {
      headers: { 'Authorization': ORACLE_AUTH, 'Accept': 'application/json' }
    });
    const data = await response.json();
    res.status(response.status).json(data);
  } catch (err) {
    res.status(500).json({ error: 'Failed to fetch trips from Oracle 26ai', message: err.message });
  }
});

app.post('/api/oracle/trips', async (req, res) => {
  try {
    const response = await fetch(`${SODA_URL}/trips`, {
      method: 'POST',
      headers: {
        'Authorization': ORACLE_AUTH,
        'Content-Type': 'application/json',
        'Accept': 'application/json'
      },
      body: JSON.stringify(req.body)
    });
    res.status(response.status).json({ success: response.status === 201 || response.status === 200 });
  } catch (err) {
    res.status(500).json({ error: 'Failed to save trip to Oracle 26ai', message: err.message });
  }
});

// 4. Oracle 26ai SODA Proxy - Convoys
app.get('/api/oracle/convoys', async (req, res) => {
  try {
    const response = await fetch(`${SODA_URL}/convoys`, {
      headers: { 'Authorization': ORACLE_AUTH, 'Accept': 'application/json' }
    });
    const data = await response.json();
    res.status(response.status).json(data);
  } catch (err) {
    res.status(500).json({ error: 'Failed to fetch convoys from Oracle 26ai', message: err.message });
  }
});

app.post('/api/oracle/convoys', async (req, res) => {
  try {
    const response = await fetch(`${SODA_URL}/convoys`, {
      method: 'POST',
      headers: {
        'Authorization': ORACLE_AUTH,
        'Content-Type': 'application/json',
        'Accept': 'application/json'
      },
      body: JSON.stringify(req.body)
    });
    res.status(response.status).json({ success: response.status === 201 || response.status === 200 });
  } catch (err) {
    res.status(500).json({ error: 'Failed to save convoy to Oracle 26ai', message: err.message });
  }
});

// 5. High-Throughput Real-Time WebSocket Telemetry Gateway
wss.on('connection', (ws, req) => {
  let clientConvoyId = null;
  let clientRiderId = null;

  ws.isAlive = true;
  ws.on('pong', () => { ws.isAlive = true; });

  ws.on('message', (message) => {
    try {
      const data = JSON.parse(message.toString());

      switch (data.type) {
        case 'JOIN': {
          clientConvoyId = data.convoyId;
          clientRiderId = data.riderId;

          if (!convoyRooms.has(clientConvoyId)) {
            convoyRooms.set(clientConvoyId, new Map());
          }
          convoyRooms.get(clientConvoyId).set(clientRiderId, ws);

          // Broadcast rider joined event
          broadcastToRoom(clientConvoyId, {
            type: 'RIDER_JOINED',
            riderId: clientRiderId,
            name: data.name,
            timestamp: Date.now()
          }, clientRiderId);
          break;
        }

        case 'TELEMETRY': {
          // Sub-30ms relay of live GPS coordinate, speed, heading, battery
          if (clientConvoyId && convoyRooms.has(clientConvoyId)) {
            broadcastToRoom(clientConvoyId, {
              type: 'TELEMETRY_UPDATE',
              riderId: data.riderId || clientRiderId,
              lat: data.lat,
              lng: data.lng,
              speedKmh: data.speedKmh,
              heading: data.heading,
              batteryLevel: data.batteryLevel,
              statusReason: data.statusReason,
              timestamp: Date.now()
            }, clientRiderId);
          }
          break;
        }

        case 'SOS': {
          // Instant emergency broadcast to entire convoy
          if (clientConvoyId && convoyRooms.has(clientConvoyId)) {
            broadcastToRoom(clientConvoyId, {
              type: 'SOS_ALERT',
              alert: data.alert,
              timestamp: Date.now()
            });
          }
          break;
        }

        case 'CHAT': {
          if (clientConvoyId && convoyRooms.has(clientConvoyId)) {
            broadcastToRoom(clientConvoyId, {
              type: 'CHAT_MESSAGE',
              message: data.message,
              timestamp: Date.now()
            });
          }
          break;
        }
      }
    } catch (e) {
      console.error('WebSocket message parsing error:', e);
    }
  });

  ws.on('close', () => {
    if (clientConvoyId && convoyRooms.has(clientConvoyId)) {
      const room = convoyRooms.get(clientConvoyId);
      room.delete(clientRiderId);
      if (room.size === 0) {
        convoyRooms.delete(clientConvoyId);
      } else {
        broadcastToRoom(clientConvoyId, {
          type: 'RIDER_LEFT',
          riderId: clientRiderId,
          timestamp: Date.now()
        });
      }
    }
  });
});

function broadcastToRoom(convoyId, payload, excludeRiderId = null) {
  const room = convoyRooms.get(convoyId);
  if (!room) return;
  const msg = JSON.stringify(payload);
  for (const [riderId, client] of room.entries()) {
    if (riderId !== excludeRiderId && client.readyState === WebSocket.OPEN) {
      client.send(msg);
    }
  }
}

// Heartbeat every 25 seconds
const interval = setInterval(() => {
  wss.clients.forEach((ws) => {
    if (ws.isAlive === false) return ws.terminate();
    ws.isAlive = false;
    ws.ping();
  });
}, 25000);

wss.on('close', () => {
  clearInterval(interval);
});

server.listen(PORT, '0.0.0.0', () => {
  console.log(`[CoRoute] Gateway running on http://0.0.0.0:${PORT}`);
  console.log(`[CoRoute] WebSocket listening on ws://0.0.0.0:${PORT}/ws/telemetry`);
});
