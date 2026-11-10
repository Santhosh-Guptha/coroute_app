#!/usr/bin/env node
'use strict';
/**
 * 3.55 diagnostics: summarise one CoRoute app log bundle (docs/features_355/diagnostics_logs.md).
 *
 *   node tool/diag/analyze_logs.js coroute-diag-dl_xxx.jsonl.gz          # text report
 *   node tool/diag/analyze_logs.js bundle.jsonl.gz --json                 # machine-readable
 *   node tool/diag/analyze_logs.js bundle.jsonl --ride G-ABC123           # one ride only
 *
 * Input: the gzip bundle from the admin console ("Download") or the phone's "Share log file", or a
 * plain .jsonl file. Reports: time range and builds, entries by level / category, errors by count,
 * alert pipeline latency (decision -> speech start, by priority), overspeed decisions, crash alarm
 * and false-alarm reasons, SOS delivery, socket drops and reconnects, GPS quality, API errors,
 * siren detections, intercom, push and friend events. Plain Node, no dependencies.
 */
const fs = require('fs');
const zlib = require('zlib');

function readLines(file) {
  let buf = fs.readFileSync(file);
  if (buf[0] === 0x1f && buf[1] === 0x8b) buf = zlib.gunzipSync(buf);
  return buf.toString('utf8').split('\n');
}

function parse(lines) {
  let meta = null;
  const entries = [];
  let bad = 0;
  for (const l of lines) {
    const s = l.trim();
    if (!s) continue;
    let o;
    try { o = JSON.parse(s); } catch { bad++; continue; }
    if (o && o.meta === 'coroute-diag') { meta = o; continue; }
    if (!o || typeof o.t !== 'number' || typeof o.e !== 'string') { bad++; continue; }
    o.f = o.f && typeof o.f === 'object' ? o.f : {};
    entries.push(o);
  }
  entries.sort((a, b) => a.t - b.t || (a.n || 0) - (b.n || 0));
  return { meta, entries, bad };
}

const inc = (m, k, n = 1) => { m[k] = (m[k] || 0) + n; return m; };
function stats(arr) {
  const v = arr.filter((x) => Number.isFinite(x)).sort((a, b) => a - b);
  if (!v.length) return null;
  const q = (p) => v[Math.min(v.length - 1, Math.round((v.length - 1) * p))];
  return { n: v.length, p50: q(0.5), p90: q(0.9), max: v[v.length - 1], avg: Math.round(v.reduce((s, x) => s + x, 0) / v.length) };
}
const top = (m, n = 10) => Object.entries(m).sort((a, b) => b[1] - a[1]).slice(0, n);

function analyze({ meta, entries, bad }, { ride } = {}) {
  const list = ride ? entries.filter((e) => e.r === ride) : entries;
  const r = {
    meta, badLines: bad, entries: list.length,
    from: list.length ? new Date(list[0].t).toISOString() : null,
    to: list.length ? new Date(list[list.length - 1].t).toISOString() : null,
    builds: {}, sessions: new Set(), rides: new Set(), byLevel: {}, byCategory: {}, topEvents: {},
    errors: {}, warnings: {},
    alerts: { decisionToAudioByPriority: {}, waitedByPriority: {}, speechStartMs: [], dropped: 0, engineRefused: 0, focus: {}, musicChanges: 0 },
    overspeed: { warns: 0, bySource: {}, fixAgeMs: [] },
    crash: { candidates: 0, candidatesByScenario: {}, dropped: {}, alarms: 0, alarmsByScenario: {}, cancels: {}, sends: {}, refused: 0, riderDown: 0 },
    sos: { raised: 0, bySource: {}, queued: 0, acks: [], sends: { ok: 0, failed: 0 }, cancels: {}, sms: {} },
    realtime: { connected: 0, connectMs: [], closed: 0, closedByCode: {}, closedInRide: 0, failures: {}, stale: 0, serverMoves: 0, upMs: [] },
    gps: { summaries: 0, hz: [], accP50: [], maxGapMs: [], rejected: 0, outliers: 0 },
    api: { errors: {}, timeouts: {}, offline: 0, slow: 0 },
    siren: { detected: 0, byKind: {}, heardS: [], alerts: 0, spoken: 0, rejectedSamples: {} },
    intercom: { talks: 0, talkMs: [], problems: {} },
    push: {}, social: {}, lifecycle: {}, native: { crashes: 0, stalls: 0, stallMs: [] },
    ridesSeen: [],
  };
  for (const e of list) {
    const f = e.f;
    inc(r.byLevel, e.l || 'I');
    inc(r.byCategory, e.c);
    inc(r.topEvents, `${e.c}.${e.e}`);
    if (e.b) inc(r.builds, e.b);
    if (e.s) r.sessions.add(e.s);
    if (e.r) r.rides.add(e.r);
    if (e.l === 'E') inc(r.errors, `${e.c}.${e.e}${f.type ? ` (${f.type})` : ''}`);
    if (e.l === 'W') inc(r.warnings, `${e.c}.${e.e}`);
    const key = `${e.c}.${e.e}`;
    switch (key) {
      case 'audio.audio': {
        const line = String(f.line || '');
        let m;
        if ((m = line.match(/P(\d)\s+\S+\s+decision->audio\s+(\d+)ms/))) (r.alerts.decisionToAudioByPriority[`P${m[1]}`] ||= []).push(+m[2]);
        else if ((m = line.match(/P(\d)\s+\S+\s+to engine: waited\s+(\d+)ms/))) (r.alerts.waitedByPriority[`P${m[1]}`] ||= []).push(+m[2]);
        else if ((m = line.match(/speech start \S* \+(\d+)ms/))) r.alerts.speechStartMs.push(+m[1]);
        if (/dropped: queue full/.test(line)) r.alerts.dropped++;
        if (/engine refused/.test(line)) r.alerts.engineRefused++;
        if ((m = line.match(/native focus \S+ \S+ (\S+)/))) inc(r.alerts.focus, m[1]);
        if (/speed music|volume/.test(line)) r.alerts.musicChanges++;
        break;
      }
      case 'speed.overspeed_warn': r.overspeed.warns++; inc(r.overspeed.bySource, f.src || '?'); r.overspeed.fixAgeMs.push(f.fixAgeMs); break;
      case 'speed.speed_outlier': r.gps.outliers++; break;
      case 'crash.impact_candidate': r.crash.candidates++; inc(r.crash.candidatesByScenario, f.scenario || '?'); break;
      case 'crash.candidate_dropped': inc(r.crash.dropped, f.why || '?'); break;
      case 'crash.alarm_open': r.crash.alarms++; inc(r.crash.alarmsByScenario, f.scenario || '?'); if (f.riderDown) r.crash.riderDown++; break;
      case 'crash.alarm_cancel': inc(r.crash.cancels, f.reason || '?'); break;
      case 'crash.alarm_ride_on': inc(r.crash.cancels, 'rode_on'); break;
      case 'crash.alarm_send': inc(r.crash.sends, f.source || '?'); break;
      case 'crash.alarm_refused': r.crash.refused++; break;
      case 'sos.raise': case 'sos.solo_sos': r.sos.raised++; inc(r.sos.bySource, f.src || '?'); if (f.sent === false) r.sos.queued++; break;
      case 'sos.ack': r.sos.acks.push(f.sinceRaiseMs); break;
      case 'sos.send': f.ok ? r.sos.sends.ok++ : r.sos.sends.failed++; break;
      case 'sos.cancel': inc(r.sos.cancels, f.reason || '?'); break;
      case 'sos.sms_fallback': inc(r.sos.sms, f.state || '?'); break;
      case 'realtime.connected': r.realtime.connected++; r.realtime.connectMs.push(f.ms); break;
      case 'realtime.closed': r.realtime.closed++; inc(r.realtime.closedByCode, String(f.code ?? 'none')); if (f.inRide) r.realtime.closedInRide++; if (f.upMs) r.realtime.upMs.push(f.upMs); break;
      case 'realtime.connect_failed': inc(r.realtime.failures, f.problem || '?'); break;
      case 'realtime.stale_link': r.realtime.stale++; break;
      case 'realtime.server_move': r.realtime.serverMoves++; break;
      case 'location.gps_summary': r.gps.summaries++; r.gps.hz.push(f.hz); r.gps.accP50.push(f.accP50); r.gps.maxGapMs.push(f.maxGapMs); r.gps.rejected += f.rejected || 0; break;
      case 'network.api_error': inc(r.api.errors, `${f.method} ${f.path} ${f.status}`); break;
      case 'network.api_timeout': inc(r.api.timeouts, `${f.method} ${f.path}`); break;
      case 'network.api_offline': r.api.offline++; break;
      case 'network.api_slow': r.api.slow++; break;
      case 'siren.detected': r.siren.detected++; inc(r.siren.byKind, `${f.kind || '?'}${f.kindSure ? '' : '?'}`); r.siren.heardS.push(f.heardS); break;
      case 'siren.alert': r.siren.alerts++; if (f.speak) r.siren.spoken++; break;
      case 'siren.candidate_rejected': inc(r.siren.rejectedSamples, String(f.why || '?').replace(/[\d.]+/g, '#')); break;
      case 'intercom.talk_start': r.intercom.talks++; break;
      case 'intercom.talk_end': r.intercom.talkMs.push(f.ms); break;
      case 'errors.native_crash': r.native.crashes++; break;
      case 'errors.native_main_stall': r.native.stalls++; r.native.stallMs.push(f.stallMs); break;
      case 'ride.ride_start': r.ridesSeen.push({ at: new Date(e.t).toISOString(), ride: e.r, kind: f.kind, riders: f.riders }); break;
      default: break;
    }
    if (e.c === 'intercom' && (e.l === 'W' || e.l === 'E')) inc(r.intercom.problems, e.e);
    if (e.c === 'push') inc(r.push, e.e + (f.kind ? `:${f.kind}` : ''));
    if (e.c === 'social') inc(r.social, e.e + (f.kind ? `:${f.kind}` : ''));
    if (e.c === 'lifecycle') inc(r.lifecycle, e.e);
  }
  // Finish: arrays -> stats, sets -> sizes.
  const s = (o, k) => { o[k] = stats(o[k]); };
  for (const p of Object.keys(r.alerts.decisionToAudioByPriority)) r.alerts.decisionToAudioByPriority[p] = stats(r.alerts.decisionToAudioByPriority[p]);
  for (const p of Object.keys(r.alerts.waitedByPriority)) r.alerts.waitedByPriority[p] = stats(r.alerts.waitedByPriority[p]);
  s(r.alerts, 'speechStartMs'); s(r.overspeed, 'fixAgeMs'); s(r.sos, 'acks'); s(r.realtime, 'connectMs'); s(r.realtime, 'upMs');
  s(r.gps, 'hz'); s(r.gps, 'accP50'); s(r.gps, 'maxGapMs'); s(r.siren, 'heardS'); s(r.intercom, 'talkMs'); s(r.native, 'stallMs');
  r.sessions = r.sessions.size;
  r.rides = r.rides.size;
  r.topEvents = Object.fromEntries(top(r.topEvents, 15));
  return r;
}

function fmtStats(x, unit = 'ms') { return x ? `n=${x.n} p50=${x.p50}${unit} p90=${x.p90}${unit} max=${x.max}${unit}` : '-'; }
function fmtMap(m) { const e = top(m, 12); return e.length ? e.map(([k, v]) => `${k}: ${v}`).join(', ') : '-'; }

function report(r) {
  const out = [];
  const h = (t) => out.push('', `== ${t}`);
  out.push(`CoRoute app log: ${r.entries} entries, ${r.from || '-'} .. ${r.to || '-'}`);
  if (r.meta) out.push(`Bundle: build ${r.meta.build || '?'}, ${r.meta.device || '?'} Android ${r.meta.os || '?'}, reason ${r.meta.reason || '?'}${r.meta.rideId ? `, ride ${r.meta.rideId}` : ''}`);
  out.push(`Builds: ${fmtMap(r.builds)} | app starts (sessions): ${r.sessions} | rides: ${r.rides} | unreadable lines: ${r.badLines}`);
  out.push(`Levels: ${fmtMap(r.byLevel)}`);
  out.push(`Categories: ${fmtMap(r.byCategory)}`);
  h('Errors by count'); out.push(fmtMap(r.errors));
  h('Warnings by count'); out.push(fmtMap(r.warnings));
  h('Alert pipeline (decision -> speech start)');
  for (const [p, x] of Object.entries(r.alerts.decisionToAudioByPriority)) out.push(`${p} decision->audio: ${fmtStats(x)}`);
  for (const [p, x] of Object.entries(r.alerts.waitedByPriority)) out.push(`${p} queue wait before the engine: ${fmtStats(x)}`);
  out.push(`speak call -> first audio: ${fmtStats(r.alerts.speechStartMs)}`);
  out.push(`dropped (queue full): ${r.alerts.dropped}, engine refused: ${r.alerts.engineRefused}, audio focus results: ${fmtMap(r.alerts.focus)}, music volume lines: ${r.alerts.musicChanges}`);
  h('Overspeed'); out.push(`warnings: ${r.overspeed.warns} (limit source ${fmtMap(r.overspeed.bySource)}); fix age at decision: ${fmtStats(r.overspeed.fixAgeMs)}`);
  h('Crash detection and false alarms');
  out.push(`impact candidates: ${r.crash.candidates} (${fmtMap(r.crash.candidatesByScenario)})`);
  out.push(`candidates dropped (why): ${fmtMap(r.crash.dropped)}`);
  out.push(`alarms: ${r.crash.alarms} (${fmtMap(r.crash.alarmsByScenario)}), rider-down: ${r.crash.riderDown}, refused: ${r.crash.refused}`);
  out.push(`alarm cancels: ${fmtMap(r.crash.cancels)} | alarm sends: ${fmtMap(r.crash.sends)}`);
  h('SOS'); out.push(`raised: ${r.sos.raised} (${fmtMap(r.sos.bySource)}), queued offline: ${r.sos.queued}, sends ok/failed: ${r.sos.sends.ok}/${r.sos.sends.failed}`);
  out.push(`server ack after raise: ${fmtStats(r.sos.acks)} | cancels: ${fmtMap(r.sos.cancels)} | SMS fallback: ${fmtMap(r.sos.sms)}`);
  h('Realtime socket');
  out.push(`connected: ${r.realtime.connected} (connect time ${fmtStats(r.realtime.connectMs)}); closed: ${r.realtime.closed} (in a ride: ${r.realtime.closedInRide}) by code ${fmtMap(r.realtime.closedByCode)}`);
  out.push(`connect failures: ${fmtMap(r.realtime.failures)}; stale links: ${r.realtime.stale}; server moves: ${r.realtime.serverMoves}; time up before a drop: ${fmtStats(r.realtime.upMs)}`);
  h('GPS'); out.push(`30 s summaries: ${r.gps.summaries}; fixes/s ${fmtStats(r.gps.hz, '')}; accuracy p50 ${fmtStats(r.gps.accP50, ' m')}; longest gap ${fmtStats(r.gps.maxGapMs)}; rejected speed fixes: ${r.gps.rejected}, outlier lines: ${r.gps.outliers}`);
  h('API'); out.push(`errors: ${fmtMap(r.api.errors)}`); out.push(`timeouts: ${fmtMap(r.api.timeouts)}; offline: ${r.api.offline}; slow (>5 s): ${r.api.slow}`);
  h('Siren'); out.push(`detected: ${r.siren.detected} (${fmtMap(r.siren.byKind)}); time heard before sure: ${fmtStats(r.siren.heardS, ' s')}; alerts: ${r.siren.alerts} (spoken ${r.siren.spoken})`);
  out.push(`rejected candidates (sampled, detailed logs only): ${fmtMap(r.siren.rejectedSamples)}`);
  h('Intercom'); out.push(`talks: ${r.intercom.talks}, length ${fmtStats(r.intercom.talkMs)}; problems: ${fmtMap(r.intercom.problems)}`);
  h('Push / friends / lifecycle'); out.push(`push: ${fmtMap(r.push)}`); out.push(`social: ${fmtMap(r.social)}`); out.push(`lifecycle: ${fmtMap(r.lifecycle)}`);
  h('Native'); out.push(`crashes: ${r.native.crashes}; main-thread stalls: ${r.native.stalls} (${fmtStats(r.native.stallMs)})`);
  if (r.ridesSeen.length) { h('Rides'); for (const x of r.ridesSeen) out.push(`${x.at} ${x.kind} ${x.ride || ''} riders=${x.riders ?? '?'}`); }
  h('Top events'); out.push(fmtMap(r.topEvents));
  return out.join('\n');
}

if (require.main === module) {
  const args = process.argv.slice(2);
  const file = args.find((a) => !a.startsWith('--'));
  if (!file) {
    console.error('usage: node tool/diag/analyze_logs.js <bundle.jsonl.gz|.jsonl> [--json] [--ride <rideId>]');
    process.exit(2);
  }
  const ri = args.indexOf('--ride');
  const ride = ri >= 0 ? args[ri + 1] : undefined;
  const result = analyze(parse(readLines(file)), { ride });
  console.log(args.includes('--json') ? JSON.stringify(result, null, 2) : report(result));
}

module.exports = { parse, analyze, report, readLines };
