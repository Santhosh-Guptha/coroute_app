/* CoRoute web admin: "Road & safety intelligence" (round 4, src/intel/, docs/intelligence/ROAD_AND_SAFETY_INTELLIGENCE.md).
   Hazard map, Crash brain, Rider stops, Road quality, Twisty roads, Dangerous times, Data & privacy.
   Maps: Leaflet 1.9.4 (BSD-2-Clause, served from /admin) with OpenStreetMap's standard tiles, admin only and low volume
   (OSM tile usage policy: attribution shown, no bulk downloads, no offline scraping). Every call is MASTER_ADMIN only. */
(function () {
  'use strict';
  var CR = window.CR;
  if (!CR) return;
  var h = CR.util.h, clear = CR.util.clear, ui = CR.ui, api = CR.api;
  var TILE = 'https://tile.openstreetmap.org/{z}/{x}/{y}.png';
  var ATTR = '&copy; <a href="https://www.openstreetmap.org/copyright" rel="noreferrer noopener" target="_blank">OpenStreetMap</a> contributors';
  var TYPE_LABEL = { hard_brake: 'Hard braking', swerve: 'Swerve', skid: 'Skid', crash: 'Crash alerts', sos: 'SOS', pothole: 'Pothole', rough: 'Rough road' };
  var DIRS = ['N', 'NE', 'E', 'SE', 'S', 'SW', 'W', 'NW'];
  var maps = [];

  function teardown() { maps.forEach(function (m) { try { m.remove(); } catch (e) { /* gone */ } }); maps = []; }

  function newMap(box) {
    if (!window.L) { box.appendChild(h('div.banner', { text: 'The map library did not load. The list below has every cell.' })); return null; }
    var m = window.L.map(box, { scrollWheelZoom: false, preferCanvas: true }).setView([20.6, 78.9], 5);
    window.L.tileLayer(TILE, { maxZoom: 18, minZoom: 3, attribution: ATTR }).addTo(m);
    maps.push(m);
    setTimeout(function () { try { m.invalidateSize(); } catch (e) { /* gone */ } }, 50);
    return m;
  }

  function fmtDate(ms) { return ms ? CR.util.date(ms, true) : '-'; }

  function downloadCsv(path, name) {
    fetch('/api' + path, { headers: { Authorization: 'Bearer ' + CR.token() } })
      .then(function (r) { if (!r.ok) throw new Error('Export failed (' + r.status + ')'); return r.blob(); })
      .then(function (b) { CR.download(b, name); ui.toast('Exported ' + name); })
      .catch(function (e) { ui.toast(e.message, true); });
  }

  function kNote(k) { return h('p.muted.small', { text: 'Only cells with at least ' + k + ' different riders (INTEL_K_MIN) are listed. Rider names and ids are never stored: a monthly one-way hash is used for counting only.' }); }

  /**
   * A map page: filters, a Leaflet map with circle markers, a table and CSV export.
   * spec: { key, title, sub, endpoint, types?, color(c), radius(c), popup(c), cols: [[label, fn]], csv }
   */
  function mapPage(spec) {
    return {
      title: spec.title,
      teardown: teardown,
      render: function (view) {
        teardown();
        var typeSel = spec.types ? ui.select([['', 'All types']].concat(spec.types.map(function (t) { return [t, TYPE_LABEL[t] || t]; })), '') : null;
        var since = ui.select([['', 'Any time'], ['7', 'Last 7 days'], ['30', 'Last 30 days'], ['90', 'Last 90 days']], '');
        var exportBtn = h('button.btn', { type: 'button', text: 'Export CSV' });
        var reload = h('button.btn.btn--ghost', { type: 'button', text: 'Refresh' });
        view.appendChild(ui.pageHead(spec.title, spec.sub, h('div.row', exportBtn, reload)));
        var filters = h('div.card.intel-filters', typeSel ? ui.field('Type', typeSel) : null, ui.field('Updated', since));
        view.appendChild(filters);
        var mapBox = h('div.intel-map', { role: 'region', 'aria-label': spec.title + ' map' });
        view.appendChild(h('div.card.intel-mapcard', mapBox, h('p.muted.small.intel-attr', { text: 'Map tiles: OpenStreetMap (standard tile server, admin use only, low volume).' })));
        var summary = h('div.tiles');
        view.appendChild(summary);
        var listBox = h('div.card', ui.loading());
        view.appendChild(listBox);
        var map = newMap(mapBox);
        var layer = map ? window.L.layerGroup().addTo(map) : null;

        function q() {
          var parts = [];
          if (typeSel && typeSel.value) parts.push('type=' + encodeURIComponent(typeSel.value));
          if (since.value) parts.push('sinceDays=' + since.value);
          return parts.length ? '?' + parts.join('&') : '';
        }
        function load() {
          clear(listBox).appendChild(ui.loading());
          api('GET', spec.endpoint + q()).then(function (r) {
            var cells = r.cells || [];
            clear(summary);
            (spec.tiles ? spec.tiles(cells) : [['Cells', String(cells.length)]]).forEach(function (t) { summary.appendChild(ui.tile(t[0], t[1], t[2])); });
            if (layer) {
              layer.clearLayers();
              var bounds = [];
              cells.forEach(function (c) {
                var mk = window.L.circleMarker([c.lat, c.lng], { radius: spec.radius ? spec.radius(c) : 6, color: spec.color(c), weight: 1, fillOpacity: 0.6 });
                mk.bindPopup(spec.popup(c));
                layer.addLayer(mk);
                bounds.push([c.lat, c.lng]);
              });
              if (bounds.length) map.fitBounds(bounds, { maxZoom: 13, padding: [20, 20] });
            }
            clear(listBox);
            listBox.appendChild(kNote(r.kMin));
            if (!cells.length) { listBox.appendChild(h('p.empty', { text: spec.empty || 'Nothing to show yet. Cells appear once enough consenting riders have ridden there.' })); return; }
            var thead = h('tr', spec.cols.map(function (c) { return h('th', { text: c[0] }); }));
            var tbody = h('tbody');
            cells.slice(0, 300).forEach(function (c) {
              var tr = h('tr', spec.cols.map(function (col) { var v = col[1](c); return h('td', v instanceof Node ? v : { text: v === undefined || v === null ? '-' : String(v) }); }));
              if (layer) tr.addEventListener('click', function () { map.setView([c.lat, c.lng], 15); });
              tbody.appendChild(tr);
            });
            listBox.appendChild(h('div.table-wrap', h('table.table', h('thead', thead), tbody)));
            if (cells.length > 300) listBox.appendChild(h('p.muted.small', { text: 'Showing the top 300 of ' + cells.length + '. Export CSV for all of them.' }));
          }).catch(function (e) { clear(listBox).appendChild(ui.error(e)); });
        }
        [since].concat(typeSel ? [typeSel] : []).forEach(function (s) { s.addEventListener('change', load); });
        reload.addEventListener('click', load);
        exportBtn.addEventListener('click', function () { downloadCsv(spec.endpoint + (q() ? q() + '&' : '?') + 'format=csv', spec.csv); });
        load();
      },
    };
  }

  function dirText(d) { return d && d.length ? d.map(function (i) { return DIRS[i]; }).join(', ') : 'both / unknown'; }
  function popupText(lines) { return lines.map(function (l) { return String(l).replace(/[&<>"']/g, function (ch) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[ch]; }); }).join('<br>'); }
  function counts(c) { return Object.keys(c.counts || {}).filter(function (k) { return c.counts[k] > 0; }).map(function (k) { return (TYPE_LABEL[k] || k) + ' ' + c.counts[k]; }).join(', '); }

  CR.sections.hazards = mapPage({
    title: 'Hazard map',
    sub: 'Spots where consenting riders braked hard, swerved, skidded, crashed or raised SOS. Scores decay with a 90-day half-life; crash and SOS weigh more than hard braking. Every rider gets the "Hazard ahead" warning for these cells.',
    endpoint: '/admin/intel/hazards', csv: 'coroute-hazards.csv',
    types: ['hard_brake', 'swerve', 'skid', 'crash', 'sos'],
    color: function (c) { return c.level === 'high' ? '#c62828' : '#ef6c00'; },
    radius: function (c) { return 5 + Math.min(10, c.score / 10); },
    popup: function (c) { return popupText(['Hazard ' + c.gh, 'Score ' + c.score + ' (' + c.level + ')', 'Riders ' + c.riders, counts(c), 'Direction ' + dirText(c.dirs)]); },
    tiles: function (cells) { return [['Hotspots', String(cells.length)], ['High', String(cells.filter(function (c) { return c.level === 'high'; }).length)], ['Shown to riders', String(cells.filter(function (c) { return c.score >= 15; }).length), 'score 15 or more']]; },
    cols: [['Cell', function (c) { return c.gh; }], ['Main signal', function (c) { return TYPE_LABEL[c.kind] || c.kind; }], ['Score', function (c) { return c.score; }], ['Riders', function (c) { return c.riders; }],
      ['Signals', counts], ['Direction', function (c) { return dirText(c.dirs); }], ['Updated', function (c) { return fmtDate(c.updatedAt); }]],
  });

  CR.sections.riderstops = mapPage({
    title: 'Rider stops',
    sub: 'Where consenting riders really stop (4 to 90 minutes, never near a ride\'s start or end), with the nearest cached fuel or food place. Used for regroup suggestions and no-fuel gap warnings.',
    endpoint: '/admin/intel/stops', csv: 'coroute-rider-stops.csv',
    color: function (c) { return c.fuel ? '#1565c0' : '#2e7d32'; },
    radius: function (c) { return 4 + Math.min(10, c.popularity / 10); },
    popup: function (c) { return popupText(['Stop ' + c.gh, c.place ? c.place.name + ' (' + c.place.cat + ')' : 'No place matched', 'Typical ' + c.typicalMin + ' min', 'Riders ' + c.riders]); },
    tiles: function (cells) { return [['Stops', String(cells.length)], ['At fuel stations', String(cells.filter(function (c) { return c.fuel; }).length)]]; },
    cols: [['Cell', function (c) { return c.gh; }], ['Place', function (c) { return c.place ? c.place.name || c.place.cat : '-'; }], ['Typical stop', function (c) { return c.typicalMin + ' min'; }],
      ['Busiest hours', function (c) { return c.peakHours ? c.peakHours[0] + ':00-' + c.peakHours[1] + ':00' : '-'; }], ['Popularity', function (c) { return c.popularity; }], ['Riders', function (c) { return c.riders; }]],
  });

  CR.sections.roadquality = mapPage({
    title: 'Road quality',
    sub: 'Potholes and rough stretches felt by consenting riders\' phones at speed (phones in a pocket are skipped or marked low confidence). Riders get an optional low-priority "Rough road ahead".',
    endpoint: '/admin/intel/road-quality', csv: 'coroute-road-quality.csv', types: ['pothole', 'rough'],
    color: function (c) { return c.kind === 'pothole' ? '#6a1b9a' : '#8d6e63'; },
    popup: function (c) { return popupText([(TYPE_LABEL[c.kind] || c.kind) + ' ' + c.gh, 'Score ' + c.score, 'Riders ' + c.riders, 'Direction ' + dirText(c.dirs)]); },
    cols: [['Cell', function (c) { return c.gh; }], ['Kind', function (c) { return TYPE_LABEL[c.kind] || c.kind; }], ['Score', function (c) { return c.score; }], ['Riders', function (c) { return c.riders; }], ['Direction', function (c) { return dirText(c.dirs); }]],
  });

  CR.sections.twisty = mapPage({
    title: 'Twisty roads',
    sub: 'Twistiness 0-100 from how much riders turn per kilometre at riding speed (cells of about 1 km). 50 and above is labelled a ghat. Riders hear "Twisty section ahead: slow down" and see twisty kilometres in their ride report.',
    endpoint: '/admin/intel/twisty', csv: 'coroute-twisty-roads.csv',
    color: function (c) { return c.ghat ? '#ad1457' : '#f9a825'; },
    popup: function (c) { return popupText(['Road ' + c.gh, 'Twistiness ' + c.score + (c.ghat ? ' (ghat)' : ''), c.degPerKm + ' deg per km over ' + c.km + ' km', 'Riders ' + c.riders]); },
    tiles: function (cells) { return [['Cells', String(cells.length)], ['Ghats', String(cells.filter(function (c) { return c.ghat; }).length)]]; },
    cols: [['Cell', function (c) { return c.gh; }], ['Twistiness', function (c) { return c.score; }], ['Ghat', function (c) { return c.ghat ? 'Yes' : 'No'; }], ['Deg / km', function (c) { return c.degPerKm; }], ['Km ridden', function (c) { return c.km; }], ['Riders', function (c) { return c.riders; }]],
  });

  CR.sections.dangertimes = {
    title: 'Dangerous times',
    teardown: teardown,
    render: function (view) {
      teardown();
      var exportBtn = h('button.btn', { type: 'button', text: 'Export CSV', onclick: function () { downloadCsv('/admin/intel/dangerous-times?format=csv', 'coroute-dangerous-times.csv'); } });
      view.appendChild(ui.pageHead('Dangerous times', 'Hazard, crash and SOS signals by region (about 40 x 20 km) and hour, India time. Riders starting a ride in a busy window get one tip a day. Weather is not included: there is no free weather source without usage limits.', exportBtn));
      var mapBox = h('div.intel-map', { role: 'region', 'aria-label': 'Dangerous times map' });
      view.appendChild(h('div.card.intel-mapcard', mapBox));
      var box = h('div.card', ui.loading());
      view.appendChild(box);
      var map = newMap(mapBox);
      api('GET', '/admin/intel/dangerous-times').then(function (r) {
        clear(box);
        box.appendChild(kNote(r.kMin));
        var list = r.regions || [];
        if (!list.length) { box.appendChild(h('p.empty', { text: 'No region has enough signals yet.' })); return; }
        var ul = h('ul.intel-insights');
        list.slice(0, 5).forEach(function (x) {
          ul.appendChild(h('li', h('b', { text: 'Most incidents near ' + x.lat.toFixed(2) + ', ' + x.lng.toFixed(2) + ' (' + x.region + '): ' }),
            String(x.window.from).padStart(2, '0') + ':00-' + String(x.window.to).padStart(2, '0') + ':00 on ' + x.window.dayType + 's (' + x.window.share + '% of its signals, mostly ' + (TYPE_LABEL[x.topType] || x.topType).toLowerCase() + ')'));
        });
        box.appendChild(ul);
        var tbody = h('tbody');
        var bounds = [];
        list.forEach(function (x) {
          bounds.push([x.lat, x.lng]);
          tbody.appendChild(h('tr', h('td', { text: x.region }), h('td', { text: x.score }), h('td', { text: x.window.dayType + ' ' + x.window.from + ':00-' + x.window.to + ':00' }), h('td', { text: x.window.share + '%' }), h('td', { text: TYPE_LABEL[x.topType] || x.topType })));
          if (map) window.L.circle([x.lat, x.lng], { radius: 12000, color: '#c62828', weight: 1, fillOpacity: 0.15 + Math.min(0.5, x.score / 100) }).bindPopup(popupText([x.region, 'Score ' + x.score, x.window.dayType + ' ' + x.window.from + ':00-' + x.window.to + ':00'])).addTo(map);
        });
        if (map && bounds.length) map.fitBounds(bounds, { maxZoom: 9, padding: [40, 40] });
        box.appendChild(h('div.table-wrap', h('table.table', h('thead', h('tr', h('th', { text: 'Region' }), h('th', { text: 'Score' }), h('th', { text: 'Busiest window' }), h('th', { text: 'Share' }), h('th', { text: 'Main signal' }))), tbody)));
      }).catch(function (e) { clear(box).appendChild(ui.error(e)); });
    },
  };

  CR.sections.crashbrain = {
    title: 'Crash brain',
    render: function (view) {
      var train = h('button.btn', { type: 'button', text: 'Train now' });
      view.appendChild(ui.pageHead('Crash brain', 'Learns from labelled crash alarms of consenting riders to suggest fewer false alarms per phone maker. Shadow mode by default: it only logs what it would have done.', train));
      var box = h('div.stack', ui.loading());
      view.appendChild(box);
      function load() {
        api('GET', '/admin/intel/crash-brain').then(function (r) { render(r); }).catch(function (e) { clear(box).appendChild(ui.error(e)); });
      }
      function render(r) {
        clear(box);
        var b = r.brain || {};
        var approvedMode = r.mode === 'approved';
        box.appendChild(h('div.banner' + (approvedMode ? '' : '.banner--info'), { text: approvedMode
          ? 'Mode: approved. Phones use the parameters below only after you approve a version, and fall back to their defaults on any error.'
          : 'Mode: ' + r.mode + '. Suggestions are only logged; phones keep their defaults. Set CRASH_BRAIN_MODE=approved on the gateway to allow approvals.' }));
        box.appendChild(h('div.card', h('h2', { text: 'Safety rules (always enforced)' }), h('ul',
          h('li', { text: 'Only the plain high-impact threshold can move, and never above the default x ' + r.scaleMax + '.' }),
          h('li', { text: 'Severe impacts, slides, low-speed falls and high-sides are never touched. The countdown is never skipped.' }),
          h('li', { text: 'A scale is only suggested if it would have missed no labelled real crash (with a 5% margin).' }),
          h('li', { text: 'At least ' + r.minLabels + ' labelled alarms in a phone group (else the global model) before anything is suggested.' }))));
        var tiles = h('div.tiles', ui.tile('Labelled alarms', String(b.total || 0)), ui.tile('Version', String(b.version || 0), b.trainedAt ? 'trained ' + fmtDate(b.trainedAt) : 'not trained yet'),
          ui.tile('Approved', b.approved ? 'v' + b.approved.version : 'None', b.approved ? 'by ' + b.approved.approvedBy + ', ' + fmtDate(b.approved.approvedAt) : 'phones use defaults'));
        box.appendChild(tiles);
        var sh = b.shadow || {};
        box.appendChild(h('div.card', h('h2', { text: 'Shadow log' }), h('p', { text: (sh.total || 0) + ' alarms checked: ' + (sh.wouldStillAlarm || 0) + ' would still alarm, ' + (sh.wouldSkipFalse || 0) + ' false alarms would have been avoided, ' + (sh.wouldSkipReal || 0) + ' real crashes would have been missed.' })));
        var rows = [['All phones (global)', b.global]].concat(Object.keys(b.groups || {}).sort().map(function (g) { return [g, b.groups[g]]; }));
        var tbody = h('tbody');
        rows.forEach(function (row) {
          var g = row[1] || {};
          var m = g.metrics || {};
          var cm = m.confusion || {};
          tbody.appendChild(h('tr', h('td', { text: row[0] }), h('td', { text: g.n || 0 }), h('td', null, ui.chip(g.ready ? 'Ready' : 'Needs ' + Math.max(0, r.minLabels - (g.n || 0)) + ' more', g.ready ? 'ok' : 'muted')),
            h('td', { text: g.suggestion ? 'x ' + g.suggestion.impactScale : '-' }),
            h('td', { text: m.falseAlarmRateBefore === undefined || m.falseAlarmRateBefore === null ? '-' : Math.round(m.falseAlarmRateBefore * 100) + '% to ' + Math.round((m.falseAlarmRateAfter || 0) * 100) + '%' }),
            h('td', { text: m.realMissed === undefined ? '-' : String(m.realMissed) }),
            h('td', { text: g.ready ? cm.tp + ' / ' + cm.fp + ' / ' + cm.tn + ' / ' + cm.fn : '-' })));
        });
        box.appendChild(h('div.card', h('h2', { text: 'Per phone group (held-out data)' }), h('div.table-wrap', h('table.table', h('thead', h('tr', h('th', { text: 'Group' }), h('th', { text: 'Labelled' }), h('th', { text: 'Status' }), h('th', { text: 'Suggested threshold' }), h('th', { text: 'False alarms before / after' }), h('th', { text: 'Real crashes missed' }), h('th', { text: 'Model TP / FP / TN / FN' }))), tbody))));
        var canApprove = approvedMode && b.version && ((b.global && b.global.ready) || Object.keys(b.groups || {}).some(function (k) { return b.groups[k].ready; }));
        var approve = h('button.btn.btn--primary', { type: 'button', text: 'Approve version ' + (b.version || 0), disabled: !canApprove });
        var rollback = h('button.btn.btn--danger', { type: 'button', text: 'Roll back', disabled: !b.approved });
        approve.addEventListener('click', function () {
          ui.confirm('Approve crash brain v' + b.version + '?', 'Phones download these thresholds within an hour (always capped at x' + r.scaleMax + ', countdown never skipped). You can roll back at any time.', 'Approve').then(function (ok) {
            if (!ok) return;
            api('POST', '/admin/intel/crash-brain/approve', { version: b.version }).then(function () { ui.toast('Approved.'); load(); }).catch(function (e) { ui.toast(e.message, true); });
          });
        });
        rollback.addEventListener('click', function () {
          ui.confirm('Roll back?', 'Phones go back to the previous approved version, or to their defaults.', 'Roll back', true).then(function (ok) {
            if (!ok) return;
            api('POST', '/admin/intel/crash-brain/rollback', {}).then(function () { ui.toast('Rolled back.'); load(); }).catch(function (e) { ui.toast(e.message, true); });
          });
        });
        box.appendChild(h('div.row', approve, rollback, approvedMode ? null : h('span.muted.small', { text: 'Approval is off in shadow mode.' })));
      }
      train.addEventListener('click', function () {
        train.disabled = true;
        api('POST', '/admin/intel/crash-brain/train', {}).then(function (r) { ui.toast('Trained on ' + r.total + ' labelled alarms (v' + r.version + ').'); load(); })
          .catch(function (e) { ui.toast(e.message, true); }).then(function () { train.disabled = false; });
      });
      load();
    },
  };

  CR.sections.dataprivacy = {
    title: 'Data & privacy',
    render: function (view) {
      view.appendChild(ui.pageHead('Data & privacy', 'What the road and safety intelligence keeps, for how long, and the tools for rider requests.'));
      var box = h('div.stack', ui.loading());
      view.appendChild(box);
      function load() { api('GET', '/admin/intel/overview').then(render).catch(function (e) { clear(box).appendChild(ui.error(e)); }); }
      function render(r) {
        clear(box);
        var s = r.settings || {}, hl = r.health || {}, c = r.consent || {};
        if (s.killed) box.appendChild(h('div.banner.banner--bad', { text: 'INTEL_KILL is on: nothing is collected and every rider gets empty answers.' }));
        else if (!s.enabled) box.appendChild(h('div.banner.banner--bad', { text: 'INTEL_ENABLED is off.' }));
        box.appendChild(h('div.tiles', ui.tile('Riders sharing', String(c.on || 0), 'of ' + (c.total || 0) + ' who answered'), ui.tile('k-anonymity', String(s.kMin), 'riders per cell (INTEL_K_MIN)'),
          ui.tile('Raw rows kept', s.rawDays + ' days', 'INTEL_RAW_DAYS'), ui.tile('Half-life', s.halfLifeDays + ' days', 'INTEL_HALF_LIFE_DAYS')));
        var ag = hl.aggregates || {};
        box.appendChild(h('div.card', h('h2', { text: 'Jobs and size' }), h('dl.kv',
          h('dt', { text: 'Last aggregation' }), h('dd', { text: fmtDate(hl.lastAggregateAt) }),
          h('dt', { text: 'Last daily run' }), h('dd', { text: fmtDate(hl.lastDailyAt) }),
          h('dt', { text: 'Aggregate cells' }), h('dd', { text: ['hz', 'rq', 'rd', 'st', 'dt'].map(function (k) { return k + ' ' + (ag[k] === undefined ? '-' : ag[k]); }).join(' · ') }),
          h('dt', { text: 'Raw rows' }), h('dd', { text: ag.raw === undefined ? '-' : String(ag.raw) + (ag.raw >= 1000 ? '+' : '') }),
          h('dt', { text: 'This node' }), h('dd', { text: hl.accumulators + ' rides being counted, ' + hl.rawQueue + ' rows queued, about ' + hl.memoryKB + ' KB' }),
          h('dt', { text: 'Rider hash key' }), h('dd', { text: s.hashKey === 'set' ? 'INTEL_HASH_KEY set' : 'Derived from the token signing key: add INTEL_HASH_KEY to the Vault' }),
          h('dt', { text: 'Crash brain' }), h('dd', { text: s.crashBrainMode }),
          h('dt', { text: 'Router' }), h('dd', { text: s.routerKind === 'valhalla' ? 'Valhalla (motorcycle)' : 'OSRM' }))));
        var purge = h('button.btn', { type: 'button', text: 'Purge old raw rows now' });
        var agg = h('button.btn', { type: 'button', text: 'Run aggregation now' });
        purge.addEventListener('click', function () { api('POST', '/admin/intel/purge', {}).then(function (x) { ui.toast(x.purged + ' raw rows older than ' + s.rawDays + ' days removed.'); load(); }).catch(function (e) { ui.toast(e.message, true); }); });
        agg.addEventListener('click', function () { api('POST', '/admin/intel/aggregate', {}).then(function (x) { ui.toast(x.folded + ' rows folded into ' + x.cells + ' cells.'); load(); }).catch(function (e) { ui.toast(e.message, true); }); });
        box.appendChild(h('div.row', purge, agg));
        box.appendChild(h('div.card', h('h2', { text: 'What is kept' }), h('ul',
          h('li', { text: 'Only riders who turned on "Help make roads safer" (off by default). Everyone still gets the warnings.' }),
          h('li', { text: 'Events (cell of about 150 m, direction, speed band, hour) and per-ride road counters. Never full tracks, medical data or phone numbers.' }),
          h('li', { text: 'The first and last ' + s.trimM + ' m of every ride are dropped, and anything near saved home / work places.' }),
          h('li', { text: 'Raw rows carry a monthly one-way rider hash and are deleted after ' + s.rawDays + ' days. Aggregates keep only decayed totals and, for the current month, short hashes used to count distinct riders.' }))));
        var uid = h('input', { type: 'text', placeholder: 'Rider user id', maxlength: '80' });
        var exp = h('button.btn', { type: 'button', text: 'Export contributions' });
        var del = h('button.btn.btn--danger', { type: 'button', text: 'Delete contributions' });
        exp.addEventListener('click', function () {
          if (!uid.value.trim()) return;
          api('GET', '/admin/intel/rider/' + encodeURIComponent(uid.value.trim()) + '/export').then(function (x) {
            CR.download(new Blob([JSON.stringify(x, null, 2)], { type: 'application/json' }), 'contributions-' + uid.value.trim() + '.json');
          }).catch(function (e) { ui.toast(e.message, true); });
        });
        del.addEventListener('click', function () {
          if (!uid.value.trim()) return;
          ui.confirm('Delete this rider\'s contributions?', 'Raw rows from the last ' + s.rawDays + ' days are removed (unprocessed at once, processed ones subtracted from the totals within minutes). Older contributions exist only inside anonymous totals and cannot be split out.', 'Delete', true).then(function (ok) {
            if (!ok) return;
            api('POST', '/admin/intel/rider/' + encodeURIComponent(uid.value.trim()) + '/delete', {}).then(function (x) { ui.toast(x.removedNow + ' rows removed, ' + x.subtractingSoon + ' being subtracted.'); }).catch(function (e) { ui.toast(e.message, true); });
          });
        });
        box.appendChild(h('div.card', h('h2', { text: 'Rider requests' }), h('p.muted', { text: 'Riders can export or delete their own contributions in the app (Settings) and on the website (/account). Use this only for a support request.' }),
          h('div.row', uid, exp, del),
          h('p.muted.small', { text: 'What can be deleted: raw rows of the last ' + s.rawDays + ' days (exact, including their share of the totals). What cannot: contributions older than that, which live only inside anonymous decayed totals with no link to the rider; and de-identified crash alarm training rows (no rider hash, no position).' })));
        box.appendChild(h('p.muted.small', { text: 'Map tiles come from tile.openstreetmap.org (OpenStreetMap Foundation tile usage policy: low volume, attribution, no bulk downloads). The admin is the only user of these maps; the app uses its own offline map cache.' }));
      }
      load();
    },
  };
  // ==================================================================== v3.62 insights (src/intel/insights.js)
  var SLOTS = ['0-4', '4-8', '8-12', '12-16', '16-20', '20-24'];
  function bars(values, labels, fmt) {
    var max = Math.max.apply(null, values.concat([1]));
    var wrap = h('div.ins-bars', { role: 'img', 'aria-label': labels.map(function (l, i) { return l + ' ' + values[i]; }).join(', ') });
    values.forEach(function (v, i) {
      wrap.appendChild(h('div.ins-bar', h('span.ins-bar__fill', { style: 'height:calc((100% - 20px) * ' + (v / max).toFixed(3) + ')' }), h('span.ins-bar__val', { text: fmt ? fmt(v) : Number(v).toLocaleString('en-IN') }), h('span.ins-bar__lbl', { text: labels[i] })));
    });
    return wrap;
  }
  function dbCard(db) {
    if (!db) return null;
    var mode = !db.separate ? 'Main database' : db.mode === 'intel' ? 'Own database' : db.mode === 'dual' ? 'Copying' : 'Main database (own one ready)';
    var state = !db.separate ? 'ok' : db.intelDb !== 'UP' ? 'bad' : db.mode === 'intel' ? 'ok' : 'warn';
    var lines = [h('div.cc-pill', h('span.cc-dot.cc-dot--' + state), h('span.cc-pill__label', { text: 'Intelligence data' }), h('span.cc-pill__text', { text: mode }))];
    var note = !db.separate ? 'INTEL_SODA_URL is not set: intelligence lives in the main database.'
      : db.mode === 'dual' ? 'Copying to the intelligence database: ' + (db.copiedTotal || 0) + ' documents so far (pass ' + ((db.progress && db.progress.pass) || 1) + '). Writes go to both until it finishes.'
      : db.mode === 'intel' ? 'Reads and writes use the intelligence database (since ' + fmtDate(db.doneAt) + '). The old copies in the main database can be removed later.'
      : 'The intelligence database is connected. Set INTEL_DB_MIGRATE=1 on one node to copy the data and switch.';
    return h('div.card.cc-card', h('div.cc-card__head', h('h2', { text: 'Intelligence database' })), h('div.cc-strip', lines), h('p.muted.small', { text: note }),
      db.mirrorErrors ? h('p.small', ui.chip(db.mirrorErrors + ' mirror errors', 'warn')) : null);
  }
  CR.sections.insights = {
    title: 'Insights',
    teardown: teardown,
    render: function (view) {
      teardown();
      var runBtn = h('button.btn.btn--sm', { type: 'button', text: 'Recompute now' });
      view.appendChild(h('div.cc-hero', h('div', h('p.cc-eyebrow', { text: 'Road & safety intelligence' }), h('h1', { text: 'Insights' }),
        h('p.muted', { text: 'Popular roads, where riders stop, monthly trends and rider risk. Anonymous, k-anonymous totals only.' })), h('span.spacer'), runBtn));
      var body = h('div', ui.loading());
      view.appendChild(body);
      runBtn.addEventListener('click', function () {
        runBtn.disabled = true;
        api('POST', '/admin/intel/insights/run', {}).then(function () { ui.toast('Insights recomputed.'); load(); }).catch(function (e) { ui.toast(e.message, true); }).then(function () { runBtn.disabled = false; });
      });
      function load() {
        api('GET', '/admin/intel/insights').then(function (r) {
          clear(body);
          var db = dbCard(r.database); if (db) body.appendChild(db);
          // Monthly trends.
          var tr = r.trends && r.trends.months ? r.trends.months : {};
          var months = Object.keys(tr).sort().slice(-12);
          var tcard = h('section.card.cc-card.section-gap', h('div.cc-card__head', h('h2', { text: 'Monthly trends' })));
          if (!months.length) tcard.appendChild(h('p.muted', { text: 'No months yet. Trends count while ride data is processed (every 5 minutes).' }));
          else {
            tcard.appendChild(h('h3.small.muted', { text: 'Km ridden (riders who share road data)' }));
            tcard.appendChild(bars(months.map(function (m) { return Math.round(tr[m].km); }), months.map(function (m) { return m.slice(2); })));
            tcard.appendChild(h('h3.small.muted', { text: 'Hard braking, swerves and skids per 1000 km' }));
            tcard.appendChild(bars(months.map(function (m) { var e = tr[m].ev || {}; var n = (e.hard_brake || 0) + (e.swerve || 0) + (e.skid || 0); return tr[m].km > 0 ? Math.round((n / tr[m].km) * 1000) : 0; }), months.map(function (m) { return m.slice(2); })));
            var last = tr[months[months.length - 1]];
            var ev = last.ev || {};
            body.appendChild(h('div.cc-kpis.section-gap',
              h('div.cc-kpi', h('div.cc-kpi__top', h('span.cc-kpi__label', { text: 'Km this month' })), h('div.cc-kpi__value', { text: Math.round(last.km).toLocaleString('en-IN') }), h('div.cc-kpi__note', { text: Math.round(last.hours) + ' riding hours' })),
              h('div.cc-kpi', h('div.cc-kpi__top', h('span.cc-kpi__label', { text: 'Hazard signals' })), h('div.cc-kpi__value', { text: String((ev.hard_brake || 0) + (ev.swerve || 0) + (ev.skid || 0)) }), h('div.cc-kpi__note', { text: 'this month' })),
              h('div.cc-kpi', h('div.cc-kpi__top', h('span.cc-kpi__label', { text: 'Road quality reports' })), h('div.cc-kpi__value', { text: String((ev.pothole || 0) + (ev.rough || 0)) }), h('div.cc-kpi__note', { text: 'potholes and rough road' })),
              h('div.cc-kpi', h('div.cc-kpi__top', h('span.cc-kpi__label', { text: 'SOS and crash' })), h('div.cc-kpi__value', { text: String((ev.sos || 0) + (ev.crash || 0)) }), h('div.cc-kpi__note', { text: 'from riders sharing road data' }))));
          }
          body.appendChild(tcard);
          // Corridors.
          var cor = r.corridors && r.corridors.list ? r.corridors.list : [];
          var ccard = h('section.card.cc-card.section-gap', h('div.cc-card__head', h('h2', { text: 'Popular roads' }), h('span.muted.small', { text: cor.length ? 'computed ' + fmtDate(r.corridors.computedAt) : '' })));
          if (!cor.length) ccard.appendChild(h('p.muted', { text: 'Not enough shared rides yet: a road shows here once at least ' + Math.max(5, r.kMin) + ' different riders rode each part of it.' }));
          else {
            var mapBox = h('div.intel-map', { style: 'height:340px' });
            ccard.appendChild(mapBox);
            var map = newMap(mapBox);
            var tb = h('tbody');
            cor.forEach(function (c, i) {
              if (map && window.L) window.L.polyline(c.path, { color: '#2B7A8C', weight: 4, opacity: 0.8 }).addTo(map).bindPopup(popupText(['Road ' + (i + 1), c.lengthKm + ' km long', c.riddenKm + ' km ridden', c.weekendShare + '% at weekends']));
              tb.appendChild(h('tr', h('td', { text: String(i + 1) }), h('td', { text: c.start[0] + ', ' + c.start[1] }), h('td', { text: c.end[0] + ', ' + c.end[1] }), h('td', { text: c.lengthKm + ' km' }),
                h('td', { text: String(c.riddenKm) }), h('td', { text: c.weekendShare + '%' }), h('td', { text: c.minRiders + '+' })));
            });
            if (map && cor[0]) { try { map.fitBounds(cor.reduce(function (a, c) { return a.concat(c.path); }, []), { padding: [20, 20] }); } catch (e) { /* empty */ } }
            ccard.appendChild(h('div.table-wrap', h('table.table', h('thead', h('tr', h('th', { text: '#' }), h('th', { text: 'From' }), h('th', { text: 'To' }), h('th', { text: 'Length' }), h('th', { text: 'Km ridden' }), h('th', { text: 'Weekend' }), h('th', { text: 'Riders' }))), tb)));
          }
          body.appendChild(ccard);
          // Stop demand.
          var sd = r.stopDemand && r.stopDemand.list ? r.stopDemand.list : [];
          var scard = h('section.card.cc-card.section-gap', h('div.cc-card__head', h('h2', { text: 'Where and when riders stop' })));
          if (!sd.length) scard.appendChild(h('p.muted', { text: 'No stop areas with enough riders yet.' }));
          else {
            var tot = [0, 0, 0, 0, 0, 0];
            sd.forEach(function (a) { a.bySlot.forEach(function (x, i) { tot[i] += x; }); });
            scard.appendChild(h('h3.small.muted', { text: 'Stops by time of day (all areas)' }));
            scard.appendChild(bars(tot, SLOTS));
            var st = h('tbody');
            sd.slice(0, 15).forEach(function (a) { st.appendChild(h('tr', h('td.mono', { text: a.area }), h('td', { text: a.lat + ', ' + a.lng }), h('td', { text: String(a.stops) }), h('td', { text: String(a.fuel) }), h('td', { text: String(a.food) }), h('td', { text: a.peak || '-' }))); });
            scard.appendChild(h('div.table-wrap', h('table.table', h('thead', h('tr', h('th', { text: 'Area' }), h('th', { text: 'Centre' }), h('th', { text: 'Stops' }), h('th', { text: 'Fuel' }), h('th', { text: 'Food' }), h('th', { text: 'Busiest' }))), st)));
          }
          body.appendChild(scard);
          // Rider risk (aggregate) + one rider (MASTER_ADMIN, audited).
          var rk = r.risk || {};
          var rcard = h('section.card.cc-card.section-gap', h('div.cc-card__head', h('h2', { text: 'Rider risk (last 30 days)' })));
          if (!rk.counts) rcard.appendChild(h('p.muted', { text: rk.note || 'Not computed yet.' }));
          else rcard.appendChild(bars([rk.counts.low, rk.counts.medium, rk.counts.high], ['Low', 'Medium', 'High']));
          rcard.appendChild(h('p.muted.small', { text: 'Hard braking, swerves and skids per 100 km, for riders with 50 km or more who share road data. Low under 2, medium 2 to 6, high 6 or more. A signal for a conversation or a safety tip, never an automatic action, and never shown to riders.' }));
          var uid = h('input', { type: 'text', placeholder: 'Rider user id', maxlength: '120', 'aria-label': 'Rider user id' });
          var out = h('div');
          var look = h('button.btn', { type: 'button', text: 'Look up one rider' });
          look.addEventListener('click', function () {
            var v = uid.value.trim(); if (!v) return;
            api('GET', '/admin/intel/rider-risk/' + encodeURIComponent(v)).then(function (x) {
              clear(out).appendChild(h('div.cc-strip', h('div.cc-pill', h('span.cc-dot.cc-dot--' + (x.bucket === 'high' ? 'bad' : x.bucket === 'medium' ? 'warn' : 'ok')), h('span.cc-pill__label', { text: 'Level' }), h('span.cc-pill__text', { text: x.bucket })),
                h('div.cc-pill', h('span.cc-pill__label', { text: 'Rate' }), h('span.cc-pill__text', { text: x.rate === null ? '-' : x.rate + ' / 100 km' })),
                h('div.cc-pill', h('span.cc-pill__label', { text: 'Km' }), h('span.cc-pill__text', { text: String(x.km) })),
                h('div.cc-pill', h('span.cc-pill__label', { text: 'SOS / crash' }), h('span.cc-pill__text', { text: x.sos + ' / ' + x.crash }))));
              out.appendChild(h('p.muted.small', { text: x.note + ' This lookup is in the audit log.' }));
            }).catch(function (e) { ui.toast(e.message, true); });
          });
          rcard.appendChild(h('div.row', uid, look));
          rcard.appendChild(out);
          body.appendChild(rcard);
          body.appendChild(kNote(Math.max(5, r.kMin)));
        }).catch(function (e) { clear(body).appendChild(ui.error(e)); });
      }
      load();
    },
  };
})();
