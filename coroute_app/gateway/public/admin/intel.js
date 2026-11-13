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
})();
